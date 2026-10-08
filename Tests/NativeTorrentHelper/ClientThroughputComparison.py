"""Compare both installed engines against the same private local seed.

All payloads and profiles are temporary. No tracker or public swarm is used.
Example: python3 ClientThroughputComparison.py --repeats 2 --remote-limit 512
"""
import argparse
import asyncio
import base64
import hashlib
import http.cookiejar
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from RequestWindowIntegrationTests import Fixture, bencode, run as run_native


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def run_qbit(binary, seed_port, fixture):
    with tempfile.TemporaryDirectory(prefix='qbit-throughput-') as root:
        directory = pathlib.Path(root)
        profile = directory / 'profile'
        config = profile / 'qBittorrent/config'
        config.mkdir(parents=True)
        password = base64.urlsafe_b64encode(os.urandom(24)).decode()
        salt = os.urandom(16)
        derived = hashlib.pbkdf2_hmac('sha512', password.encode(), salt, 100000)
        encoded = base64.b64encode(salt).decode() + ':' + base64.b64encode(derived).decode()
        web_port, peer_port = free_port(), free_port()
        (config / 'qBittorrent.ini').write_text(
            '[LegalNotice]\nAccepted=true\n[Preferences]\nWebUI\\Enabled=true\n'
            f'WebUI\\Address=127.0.0.1\nWebUI\\Port={web_port}\n'
            f'WebUI\\Username=admin\nWebUI\\Password_PBKDF2="@ByteArray({encoded})"\n'
            f'[BitTorrent]\nSession\\Port={peer_port}\nSession\\QueueingSystemEnabled=false\n')
        base = f'http://127.0.0.1:{web_port}'
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

        def api(path, data=None, content_type=None):
            if isinstance(data, dict):
                data = urllib.parse.urlencode(data).encode()
            headers = {'Referer': base}
            if content_type:
                headers['Content-Type'] = content_type
            with opener.open(urllib.request.Request(base + '/api/v2/' + path,
                            data=data, headers=headers), timeout=5) as response:
                return response.read()

        with (directory / 'process.log').open('w') as log:
            proc = subprocess.Popen([str(binary), '--profile=' + str(profile), '--no-splash'],
                                    stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        api('auth/login', {'username': 'admin', 'password': password})
                        version = api('app/version').decode()
                        break
                    except OSError:
                        if proc.poll() is not None:
                            raise RuntimeError('qBittorrent exited during startup')
                        time.sleep(0.1)
                else:
                    raise RuntimeError('qBittorrent API did not start')
                engine = json.loads(api('app/buildInfo'))
                api('app/setPreferences', {'json': json.dumps({
                    'dht': False, 'pex': False, 'lsd': False, 'upnp': False,
                    'bittorrent_protocol': 1, 'encryption': 2,
                    'max_connec': 500, 'max_connec_per_torrent': 100,
                    'preallocate_all': False, 'dl_limit': 0, 'up_limit': 0,
                    'queueing_enabled': False})})
                boundary = 'test-' + os.urandom(12).hex()
                parts = []
                for name, value in [('savepath', str(directory)), ('stopped', 'false')]:
                    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="torrents"; filename="test.torrent"\r\nContent-Type: application/x-bittorrent\r\n\r\n'.encode()
                             + bencode({b'info': fixture.info}) + b'\r\n')
                parts.append(f'--{boundary}--\r\n'.encode())
                started = time.monotonic()
                api('torrents/add', b''.join(parts), 'multipart/form-data; boundary=' + boundary)
                torrent_hash = fixture.info_hash.hex()
                # Addition is asynchronous in qBittorrent. A peer injected
                # before the torrent is registered can be silently discarded.
                registration_deadline = time.monotonic() + 10
                while time.monotonic() < registration_deadline:
                    registered = json.loads(api('torrents/info'))
                    if any(t['hash'] == torrent_hash for t in registered):
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError('The uploaded local torrent was not registered')
                api('torrents/addPeers', {'hashes': torrent_hash, 'peers': f'127.0.0.1:{seed_port}'})
                samples = []
                peak = 0
                last_sample = 0
                while time.monotonic() - started < 150:
                    torrents = json.loads(api('torrents/info'))
                    if torrents:
                        torrent = torrents[0]
                        elapsed = time.monotonic() - started
                        peak = max(peak, torrent['dlspeed'])
                        if elapsed - last_sample >= 5:
                            samples.append([round(elapsed, 1), torrent['dlspeed']])
                            last_sample = elapsed
                        if torrent['progress'] == 1:
                            break
                    time.sleep(0.1)
                else:
                    raise AssertionError('qBittorrent local transfer did not finish')
                completed_at = time.monotonic()
                elapsed = completed_at - started
                payload = directory / 'window-test.bin'
                assert payload.stat().st_size == fixture.count * len(fixture.piece)
                with payload.open('rb') as stream:
                    for _ in range(fixture.count):
                        assert hashlib.sha1(stream.read(len(fixture.piece))).digest() == hashlib.sha1(fixture.piece).digest()
                return {'seconds': round(elapsed, 2), 'MBps': round(payload.stat().st_size / elapsed / 1e6, 2),
                        'actual_peer_window': fixture.max_pending, 'peak': peak, 'samples': samples,
                        'wire_seconds': round(fixture.last_reply_at - fixture.first_reply_at, 3),
                        'finish_notification_delay': round(completed_at - fixture.last_reply_at, 3),
                        'client_version': version, 'engine': engine['libtorrent']}
            finally:
                if proc.poll() is None:
                    try:
                        api('torrents/stop', {'hashes': 'all'})
                        api('app/shutdown', {})
                    except OSError:
                        proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


async def main(args):
    rows = []
    for repeat in range(args.repeats):
        # Reverse the order to reduce advantages from cache or startup timing.
        order = ['qbittorrent', 'torravia'] if repeat % 2 == 0 else ['torravia', 'qbittorrent']
        for client in order:
            fixture = Fixture(count=args.pieces, delay=args.delay, remote_limit=args.remote_limit)
            server = await asyncio.start_server(fixture.seed, '127.0.0.1', 0)
            async with server:
                port = server.sockets[0].getsockname()[1]
                runner = run_qbit if client == 'qbittorrent' else run_native
                binary = args.qbittorrent if client == 'qbittorrent' else args.helper
                result = await asyncio.to_thread(runner, binary, port, fixture)
            result.update(client=client, repeat=repeat + 1, delay=args.delay, remote_limit=args.remote_limit,
                          bytes=fixture.count * len(fixture.piece))
            if args.remote_limit is not None:
                assert fixture.max_pending <= args.remote_limit, (
                    client, 'Remote request capacity exceeded', fixture.max_pending, args.remote_limit)
            rows.append(result)
            print(json.dumps(result), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=pathlib.Path, default=pathlib.Path('/Applications/Torravia.app/Contents/MacOS/TorrentNativeHelper'))
    parser.add_argument('--qbittorrent', type=pathlib.Path, default=pathlib.Path('/Applications/qBittorrent.app/Contents/MacOS/qbittorrent'))
    parser.add_argument('--pieces', type=int, default=512)
    parser.add_argument('--delay', type=float, default=0.25)
    parser.add_argument('--remote-limit', type=int)
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.pieces <= 0 or args.pieces % 8 != 0:
        parser.error('--pieces must be a positive multiple of 8')
    if args.delay < 0 or args.repeats <= 0:
        parser.error('--delay must be nonnegative and --repeats must be positive')
    if args.remote_limit is not None and not 1 <= args.remote_limit <= 65_535:
        parser.error('--remote-limit must be between 1 and 65535')
    asyncio.run(main(args))
