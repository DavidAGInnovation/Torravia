"""Check direct torrent layout, collisions, partial resume and verified transfer.

Usage: python3 ContentLayoutIntegrationTests.py <helper>
All payloads, metainfo, resume data and the seed are private and local.
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

from RequestWindowIntegrationTests import Fixture


def bencode(value):
    if isinstance(value, int):
        return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes):
        return str(len(value)).encode() + b':' + value
    if isinstance(value, list):
        return b'l' + b''.join(bencode(v) for v in value) + b'e'
    if isinstance(value, dict):
        return b'd' + b''.join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(type(value))


def bdecode(data, position=0):
    token = data[position:position + 1]
    if token == b'i':
        end = data.index(b'e', position)
        return int(data[position + 1:end]), end + 1
    if token == b'l':
        result = []
        position += 1
        while data[position:position + 1] != b'e':
            value, position = bdecode(data, position)
            result.append(value)
        return result, position + 1
    if token == b'd':
        result = {}
        position += 1
        while data[position:position + 1] != b'e':
            key, position = bdecode(data, position)
            result[key], position = bdecode(data, position)
        return result, position + 1
    colon = data.index(b':', position)
    length = int(data[position:colon])
    return data[colon + 1:colon + 1 + length], colon + 1 + length


async def metadata_seed(fixture, reader, writer):
    metadata = bencode(fixture.info)
    try:
        handshake = await reader.readexactly(68)
        assert handshake[28:48] == fixture.info_hash
        writer.write(b'\x13BitTorrent protocol' + b'\0\0\0\0\0\x10\0\0'
                     + fixture.info_hash + b'-META00-012345678901')

        async def send(body):
            writer.write(struct.pack('!I', len(body)) + body)
            await writer.drain()

        await send(b'\x14\0' + bencode({b'm': {b'ut_metadata': 1}, b'metadata_size': len(metadata)}))
        remote_extension = None
        while True:
            length, = struct.unpack('!I', await reader.readexactly(4))
            body = await reader.readexactly(length)
            if len(body) == 13 and body[0] == 6:
                index, begin, size = struct.unpack('!III', body[1:])
                assert index < fixture.count and begin + size <= len(fixture.piece)
                await send(b'\x07' + struct.pack('!II', index, begin) + fixture.piece[begin:begin + size])
                continue
            if len(body) < 2 or body[0] != 20:
                continue
            header, _ = bdecode(body[2:])
            if body[1] == 0:
                remote_extension = header[b'm'][b'ut_metadata']
            elif body[1] == 1 and header[b'msg_type'] == 0:
                index = header[b'piece']
                response = bencode({b'msg_type': 1, b'piece': index, b'total_size': len(metadata)})
                await send(bytes([20, remote_extension]) + response + metadata[index * 16384:(index + 1) * 16384])
                await send(b'\x05' + b'\xff' * (fixture.count // 8))
                await send(b'\x01')
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        writer.close()


class Helper:
    def __init__(self, binary, directory):
        self.process = subprocess.Popen([binary], cwd=directory, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.events = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.events.put(json.loads(line))

        threading.Thread(target=read, daemon=True).start()
        self.wait(lambda e: e['type'] == 'ready')
        self.send(type='configure', networkInterface='127.0.0.1', transportMode='tcp',
                  encryptionMode='disabled', dhtEnabled=False, peerExchangeEnabled=False,
                  localPeerDiscoveryEnabled=False, upnpEnabled=False, natpmpEnabled=False,
                  queueingEnabled=False)

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()

    def wait(self, predicate, poll=None):
        deadline = time.monotonic() + 30
        seen = []
        while time.monotonic() < deadline:
            if poll:
                poll()
            try:
                event = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            assert event['type'] not in ('error', 'storageError'), event
            if event['type'] == 'progress' and not event['isProgressReady']:
                assert not event['isFinished'], event
            seen.append(event)
            if predicate(event):
                return event
        raise AssertionError(f'Timed out; last progress: {[e for e in seen if e["type"] == "progress"][-2:]}; other events: {[e for e in seen if e["type"] != "networkStatus"][-5:]}')

    def close(self):
        if self.process.poll() is not None:
            return
        self.send(type='shutdown')
        self.process.stdin.close()
        self.process.wait(timeout=15)
        assert self.process.returncode == 0


def exercise(binary, root, fixture, port, metadata_port):
    root = pathlib.Path(root)
    downloads = root / 'Downloads'
    staging = downloads / '.TorrentScout' / 'layout-test'
    payload = staging / 'Original Folder'
    payload.mkdir(parents=True)
    (payload / 'subfolder').mkdir()
    size = len(fixture.piece)
    (payload / 'a.bin').write_bytes(fixture.piece * 4 + b'\0' * (size * 4))
    (payload / 'subfolder' / 'b.bin').write_bytes(b'\0' * (size * 8))
    # A pre-existing folder must remain completely untouched.
    original = downloads / 'Original Folder'
    original.mkdir()
    marker = original / 'a.bin'
    marker.write_bytes(b'unrelated existing content')
    torrent = root / 'folder.torrent'
    torrent.write_bytes(bencode({b'info': fixture.info}))
    command = dict(id='layout-test', input=str(torrent), destination=str(staging), contentRoot=str(downloads))
    expected_paths = ['Original Folder-2/a.bin', 'Original Folder-2/subfolder/b.bin']
    helper = Helper(binary, root)
    try:
        helper.send(type='add', **command)
        added = helper.wait(lambda e: e['type'] == 'added')
        assert pathlib.Path(added['path']) == downloads, added
        assert [f['name'] for f in added['files']] == expected_paths, added
        helper.wait(lambda e: e['type'] == 'progress' and e['isProgressReady'] and e['progress'] == 0.25)
        helper.send(type='pause', id=command['id'])
        helper.wait(lambda e: e['type'] == 'paused')
    finally:
        helper.close()

    # A metadata-less magnet must use the exact same final layout.
    magnet_root = root / 'Magnet Downloads'
    staging = magnet_root / '.TorrentScout' / 'magnet-test'
    staging.mkdir(parents=True)
    helper = Helper(binary, root)
    try:
        helper.send(type='add', id='magnet-test',
                    input='magnet:?xt=urn:btih:' + fixture.info_hash.hex(),
                    destination=str(staging), contentRoot=str(magnet_root))
        helper.wait(lambda e: e['type'] == 'discovery' and e['id'] == 'magnet-test',
                    poll=lambda: helper.send(type='getDiscovery', id='magnet-test'))
        helper.send(type='addPeer', id='magnet-test', address=f'127.0.0.1:{metadata_port}')
        added = helper.wait(lambda e: e['type'] == 'added')
        assert pathlib.Path(added['path']) == magnet_root, added
        assert [f['name'] for f in added['files']] == ['Original Folder/a.bin', 'Original Folder/subfolder/b.bin'], added
        helper.wait(lambda e: e['type'] == 'done')
        assert (magnet_root / 'Original Folder' / 'a.bin').read_bytes() == fixture.piece * 8
        assert (magnet_root / 'Original Folder' / 'subfolder' / 'b.bin').read_bytes() == fixture.piece * 8
    finally:
        helper.close()

    helper = Helper(binary, root)
    try:
        # Also exercise a stale app path: fast-resume knows placement finished.
        helper.send(type='resume', **command)
        added = helper.wait(lambda e: e['type'] == 'added')
        assert pathlib.Path(added['path']) == downloads, added
        assert [f['name'] for f in added['files']] == expected_paths, added
        helper.wait(lambda e: e['type'] == 'progress' and e['isProgressReady'] and e['progress'] == 0.25)
        helper.close()
        # Recover the app's effective paths even if helper resume data is lost.
        for path in list(root.glob('resume-state.sqlite3*')) + list(root.glob('torrent-layout-test.fastresume')):
            path.unlink()
        helper = Helper(binary, root)
        helper.send(type='resume', **{**command, 'destination': str(downloads), 'filePaths': expected_paths})
        added = helper.wait(lambda e: e['type'] == 'added')
        assert [f['name'] for f in added['files']] == expected_paths, added
        helper.wait(lambda e: e['type'] == 'progress' and e['isProgressReady'] and e['progress'] == 0.25)
        helper.send(type='addPeer', id=command['id'], address=f'127.0.0.1:{port}')
        done = helper.wait(lambda e: e['type'] == 'done')
        assert [f['name'] for f in done['files']] == expected_paths, done
        for path in expected_paths:
            data = (downloads / path).read_bytes()
            assert len(data) == size * 8
            for offset in range(0, len(data), size):
                assert hashlib.sha1(data[offset:offset + size]).digest() == hashlib.sha1(fixture.piece).digest()
        assert marker.read_bytes() == b'unrelated existing content'
        finished = helper.wait(lambda e: e['type'] == 'progress' and e['isFinished'])
        assert finished['isProgressReady'] and finished['progress'] == 1, finished
        # A completion rejected by the app triggers a recheck. The helper must
        # announce completion again after verification, even without a restart.
        helper.send(type='forceRecheck', id=command['id'])
        checked = helper.wait(lambda e: e['type'] == 'done')
        assert [f['name'] for f in checked['files']] == expected_paths, checked
        helper.send(type='cancel', id=command['id'], destroyData=True)
        helper.wait(lambda e: e['type'] == 'cancelled')
        deadline = time.monotonic() + 10
        while any((downloads / p).exists() for p in expected_paths) and time.monotonic() < deadline:
            threading.Event().wait(0.05)
        assert all(not (downloads / p).exists() for p in expected_paths)
        assert marker.read_bytes() == b'unrelated existing content'
        assert downloads.exists()
    finally:
        helper.close()

    # A single file uses its filename, with a suffix before the extension.
    staging = downloads / '.TorrentScout' / 'single-test'
    staging.mkdir(parents=True, exist_ok=True)
    (staging / 'single.bin').write_bytes(fixture.piece)
    (downloads / 'single.bin').write_bytes(b'keep this file')
    info = {b'name': b'single.bin', b'length': size, b'piece length': size,
            b'pieces': hashlib.sha1(fixture.piece).digest(), b'private': 1}
    torrent = root / 'single.torrent'
    torrent.write_bytes(bencode({b'info': info}))
    helper = Helper(binary, root)
    try:
        helper.send(type='add', id='single-test', input=str(torrent),
                    destination=str(staging), contentRoot=str(downloads))
        added = helper.wait(lambda e: e['type'] == 'added')
        assert added['files'][0]['name'] == 'single-2.bin', added
        helper.wait(lambda e: e['type'] == 'done')
        assert (downloads / 'single-2.bin').read_bytes() == fixture.piece
        assert (downloads / 'single.bin').read_bytes() == b'keep this file'
        # A stale finished snapshot during asynchronous rechecking must not
        # announce success for a completed file that is now damaged.
        (downloads / 'single-2.bin').write_bytes(b'\0' * size)
        helper.send(type='forceRecheck', id='single-test')

        def damaged_checked(event):
            assert event['type'] != 'done', event
            return (event['type'] == 'progress' and event['isProgressReady']
                    and event['progress'] == 0 and not event['isFinished'])

        helper.wait(damaged_checked)
        (downloads / 'single-2.bin').write_bytes(fixture.piece)
        helper.send(type='forceRecheck', id='single-test')
        helper.wait(lambda e: e['type'] == 'done')
    finally:
        helper.close()

    # Reserve names even before either torrent has downloaded a byte.
    # macOS filenames can collide through case differences as well.
    empty_root = root / 'Empty Downloads'
    helper = Helper(binary, root)
    try:
        for index, (name, expected) in enumerate([(b'collision.bin', 'collision.bin'),
                                                 (b'Collision.bin', 'Collision-2.bin')]):
            staging = empty_root / '.TorrentScout' / str(index)
            staging.mkdir(parents=True)
            info = {b'name': name, b'length': size, b'piece length': size,
                    b'pieces': hashlib.sha1(bytes([index]) * size).digest(), b'private': 1}
            torrent = root / f'empty-{index}.torrent'
            torrent.write_bytes(bencode({b'info': info}))
            helper.send(type='add', id=f'empty-{index}', input=str(torrent),
                        destination=str(staging), contentRoot=str(empty_root))
            added = helper.wait(lambda e: e['type'] == 'added' and e['id'] == f'empty-{index}')
            assert added['files'][0]['name'] == expected, added
    finally:
        helper.close()


async def main():
    fixture = Fixture(count=16, delay=0.02, remote_limit=32)
    fixture.info = {b'name': b'Original Folder', b'piece length': len(fixture.piece),
        b'pieces': hashlib.sha1(fixture.piece).digest() * 16, b'private': 1,
        b'files': [{b'length': len(fixture.piece) * 8, b'path': [b'a.bin']},
                   {b'length': len(fixture.piece) * 8, b'path': [b'subfolder', b'b.bin']}]}
    fixture.info_hash = hashlib.sha1(bencode(fixture.info)).digest()
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='torravia-layout-') as root:
        server = await asyncio.start_server(fixture.seed, '127.0.0.1', 0)
        metadata = await asyncio.start_server(lambda r, w: metadata_seed(fixture, r, w), '127.0.0.1', 0)
        async with server, metadata:
            await asyncio.to_thread(exercise, binary, root, fixture,
                server.sockets[0].getsockname()[1], metadata.sockets[0].getsockname()[1])
    print('Direct folder/file/magnet layout, collision protection, partial restart, piece hashes and scoped deletion verified')


if __name__ == '__main__':
    asyncio.run(main())
