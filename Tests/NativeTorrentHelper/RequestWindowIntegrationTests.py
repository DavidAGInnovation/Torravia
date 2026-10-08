"""Exercise real peer request windows against an isolated local seed.

Usage: python3 RequestWindowIntegrationTests.py <helper> [baseline-helper]
No public tracker or swarm is contacted. Temporary payloads are removed on exit.
"""
import asyncio
import hashlib
import json
import pathlib
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time


def bencode(value):
    if isinstance(value, int):
        return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes):
        return str(len(value)).encode() + b':' + value
    if isinstance(value, dict):
        return b'd' + b''.join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(type(value))


class Fixture:
    def __init__(self, count=256, delay=2.0, remote_limit=None):
        self.piece = b'\xab' * (1024 * 1024)
        self.count = count
        self.delay = delay
        self.remote_limit = remote_limit
        self.max_pending = 0
        self.first_reply_at = None
        self.last_reply_at = None
        self.info = {b'length': count * len(self.piece), b'name': b'window-test.bin',
                     b'piece length': len(self.piece),
                     b'pieces': hashlib.sha1(self.piece).digest() * count, b'private': 1}
        self.info_hash = hashlib.sha1(bencode(self.info)).digest()

    async def seed(self, reader, writer, *, incoming=False):
        requests = asyncio.Queue()
        pending = set()

        async def send_replies():
            while True:
                due, request = await requests.get()
                await asyncio.sleep(max(0, due - time.monotonic()))
                if request not in pending:
                    continue
                pending.remove(request)
                index, begin, length = request
                body = b'\x07' + struct.pack('!II', index, begin) + self.piece[begin:begin + length]
                writer.write(struct.pack('!I', len(body)) + body)
                await writer.drain()
                self.last_reply_at = time.monotonic()
                if self.first_reply_at is None:
                    self.first_reply_at = self.last_reply_at

        sender = None
        try:
            reserved = b'\0\0\0\0\0\x10\0\0'
            greeting = b'\x13BitTorrent protocol' + reserved + self.info_hash + b'-TEST00-012345678901'
            if incoming:
                writer.write(greeting)
                await writer.drain()
            handshake = await reader.readexactly(68)
            assert handshake[28:48] == self.info_hash
            if not incoming:
                writer.write(greeting)
            extensions = {b'm': {}, b'v': b'Local test seed'}
            if self.remote_limit is not None:
                extensions[b'reqq'] = self.remote_limit
            for body in [b'\x14\x00' + bencode(extensions),
                         b'\x05' + b'\xff' * (self.count // 8), b'\x01']:
                writer.write(struct.pack('!I', len(body)) + body)
            await writer.drain()
            sender = asyncio.create_task(send_replies())
            while True:
                length, = struct.unpack('!I', await reader.readexactly(4))
                body = await reader.readexactly(length)
                if length == 13 and body[0] in (6, 8):
                    request = struct.unpack('!III', body[1:])
                    if body[0] == 8:
                        pending.discard(request)
                        continue
                    index, begin, size = request
                    assert index < self.count and begin + size <= len(self.piece)
                    pending.add(request)
                    self.max_pending = max(self.max_pending, len(pending))
                    await requests.put((time.monotonic() + self.delay, request))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            if sender:
                sender.cancel()
                try:
                    await sender
                except (asyncio.CancelledError, ConnectionError):
                    pass
            writer.close()


def run(helper, port, fixture, *, tracker_url=None):
    with tempfile.TemporaryDirectory(prefix='torravia-window-') as root:
        directory = pathlib.Path(root)
        torrent = directory / 'test.torrent'
        metainfo = {b'info': fixture.info}
        if tracker_url:
            metainfo[b'announce'] = tracker_url.encode()
        torrent.write_bytes(bencode(metainfo))
        proc = subprocess.Popen([str(pathlib.Path(helper).resolve())], cwd=root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        events = queue.Queue()

        def read_events():
            for line in proc.stdout:
                events.put(json.loads(line))

        threading.Thread(target=read_events, daemon=True).start()

        def send(**event):
            proc.stdin.write(json.dumps(event) + '\n')
            proc.stdin.flush()

        started = time.monotonic()
        warnings, limits, samples = [], [], []
        done = False
        last_sample = 0
        added_at = None
        metadata_seconds = None
        first_reported_MBps_seconds = None
        try:
            assert events.get(timeout=5)['type'] == 'ready'
            send(type='configure', networkInterface='127.0.0.1', transportMode='tcp',
                 encryptionMode='disabled', dhtEnabled=False, peerExchangeEnabled=False,
                 localPeerDiscoveryEnabled=False, upnpEnabled=False, natpmpEnabled=False)
            added_at = time.monotonic()
            send(type='add', id='window-test', input=str(torrent), destination=root)
            while time.monotonic() - started < 150:
                try:
                    event = events.get(timeout=1)
                except queue.Empty:
                    continue
                if event['type'] == 'added':
                    if metadata_seconds is None:
                        metadata_seconds = time.monotonic() - added_at
                    if not tracker_url:
                        send(type='addPeer', id='window-test', address=f'127.0.0.1:{port}')
                if event['type'] == 'warning':
                    warnings.append(event.get('message', ''))
                if event['type'] == 'progress':
                    limits.append(event.get('requestQueueLimit', 0))
                    if first_reported_MBps_seconds is None and event['downloadSpeed'] >= 1_000_000:
                        first_reported_MBps_seconds = time.monotonic() - added_at
                    elapsed = time.monotonic() - started
                    if elapsed - last_sample >= 5:
                        samples.append([round(elapsed, 1), event['downloadSpeed'],
                                        event.get('requestQueueLimit', 0)])
                        last_sample = elapsed
                if event['type'] == 'error':
                    raise AssertionError(event)
                if event['type'] == 'done':
                    done = True
                    break
            completed_at = time.monotonic()
            elapsed = completed_at - started
            assert done, 'Local transfer did not finish'
            payload = directory / 'window-test.bin'
            assert payload.stat().st_size == fixture.count * len(fixture.piece)
            with payload.open('rb') as stream:
                for _ in range(fixture.count):
                    assert hashlib.sha1(stream.read(len(fixture.piece))).digest() == hashlib.sha1(fixture.piece).digest()
            return dict(seconds=round(elapsed, 2), MBps=round(payload.stat().st_size / elapsed / 1e6, 2),
                        metadata_seconds=round(metadata_seconds, 3),
                        first_payload_seconds=round(fixture.first_reply_at - added_at, 3),
                        first_reported_MBps_seconds=(round(first_reported_MBps_seconds, 3)
                                                    if first_reported_MBps_seconds is not None else None),
                        request_limit=max(limits, default=0), actual_peer_window=fixture.max_pending,
                        wire_seconds=round(fixture.last_reply_at - fixture.first_reply_at, 3),
                        finish_notification_delay=round(completed_at - fixture.last_reply_at, 3),
                        warnings=warnings, samples=samples)
        finally:
            if proc.poll() is None:
                send(type='shutdown')
            proc.stdin.close()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


async def transfer(helper, fixture):
    server = await asyncio.start_server(fixture.seed, '127.0.0.1', 0)
    async with server:
        return await asyncio.to_thread(run, helper, server.sockets[0].getsockname()[1], fixture)


async def main():
    if len(sys.argv) > 2:
        before = await transfer(sys.argv[2], Fixture())
        print('BASELINE', json.dumps(before), flush=True)
    after = await transfer(sys.argv[1], Fixture())
    print('FIXED', json.dumps(after), flush=True)
    assert after['actual_peer_window'] > 1_032, 'The active peer window did not grow'
    if len(sys.argv) > 2:
        assert after['actual_peer_window'] > before['actual_peer_window'], (before, after)
        assert after['seconds'] < before['seconds'] * 0.95, (before, after)
    capped = await transfer(sys.argv[1], Fixture(count=16, delay=0.02, remote_limit=32))
    print('REMOTE_LIMIT', json.dumps(capped), flush=True)
    assert capped['actual_peer_window'] <= 32, 'A remote advertised limit was exceeded'


if __name__ == '__main__':
    asyncio.run(main())
