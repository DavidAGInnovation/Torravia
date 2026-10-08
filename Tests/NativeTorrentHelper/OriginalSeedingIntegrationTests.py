"""Verify uploads of originals, corruption/restart checks and safe removal over loopback."""
import hashlib
import pathlib
import queue
import socket
import sqlite3
import struct
import sys
import tempfile
import time

from ContentLayoutIntegrationTests import Helper, bencode, bdecode
from PeerSourcesIntegrationTests import listening_port


def read_exact(connection, length):
    result = b''
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        assert chunk, 'Peer disconnected'
        result += chunk
    return result


def receive_payload(port, info_hash, length):
    with socket.create_connection(('127.0.0.1', port), timeout=15) as connection:
        connection.settimeout(20)
        connection.sendall(b'\x13BitTorrent protocol' + b'\0' * 8 + info_hash + b'-TS0001-local-test001'[:20])
        handshake = read_exact(connection, 68)
        assert handshake[28:48] == info_hash
        def send(message):
            connection.sendall(struct.pack('!I', len(message)) + message)
        send(b'\x02')  # interested
        while True:
            size = struct.unpack('!I', read_exact(connection, 4))[0]
            message = read_exact(connection, size) if size else b''
            if message[:1] == b'\x01':  # unchoke
                break
        result = b''
        for index, offset in enumerate(range(0, length, 16384)):
            wanted = min(16384, length - offset)
            send(b'\x06' + struct.pack('!III', index, 0, wanted))
            while True:
                size = struct.unpack('!I', read_exact(connection, 4))[0]
                message = read_exact(connection, size) if size else b''
                if message[:1] == b'\x07':
                    assert struct.unpack('!II', message[1:9]) == (index, 0)
                    assert len(message[9:]) == wanted
                    result += message[9:]
                    break
        return result


def start(binary, state):
    helper = Helper(binary, str(state))
    port = listening_port()
    helper.send(type='configure', listenPort=port, networkInterface='127.0.0.1',
        transportMode='tcp', encryptionMode='disabled', dhtEnabled=False,
        peerExchangeEnabled=False, localPeerDiscoveryEnabled=False, upnpEnabled=False,
        natpmpEnabled=False, queueingEnabled=True, preallocateFiles=True)
    helper.wait(lambda event: event['type'] == 'networkStatus' and event['isListening'] and event['listenPort'] == port)
    return helper, port


def wait_failure(helper):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            event = helper.events.get(timeout=0.2)
        except queue.Empty:
            continue
        assert event['type'] != 'done', event
        if event['type'] in ('storageError', 'error'):
            return event
    raise AssertionError('Mismatched original was not rejected')


def exercise(binary, multifile, renamed=False):
    with tempfile.TemporaryDirectory(prefix='torravia-original-seed-') as temporary:
        root = pathlib.Path(temporary)
        state = root / 'state'; state.mkdir()
        originals = root / 'originals'; originals.mkdir()
        payload = bytes(index % 251 for index in range(50_123))
        name = b'Shared Folder' if multifile else b'sample.bin'
        info = {b'name': name, b'piece length': 16384, b'private': 1,
                b'pieces': b''.join(hashlib.sha1(payload[i:i+16384]).digest() for i in range(0, len(payload), 16384))}
        if multifile:
            folder = originals / name.decode(); (folder / 'nested').mkdir(parents=True)
            first = folder / 'a.bin'; first.write_bytes(payload[:10_000])
            second = folder / 'nested/b.bin'; second.write_bytes(payload[10_000:])
            (folder / 'empty.bin').write_bytes(b'')
            info[b'files'] = [{b'length': 10000, b'path': [b'a.bin']},
                             {b'length': 0, b'path': [b'empty.bin']},
                             {b'length': len(payload)-10000, b'path': [b'nested', b'b.bin']}]
            paths = ['Shared Folder/a.bin', 'Shared Folder/empty.bin', 'Shared Folder/nested/b.bin']
        else:
            first = originals / name.decode(); first.write_bytes(payload)
            paths = ['sample.bin']; info[b'length'] = len(payload)
        if renamed:
            selected_name = 'Renamed Folder' if multifile else 'renamed.bin'
            selected = originals / selected_name
            (originals / name.decode()).rename(selected)
            first = selected / 'a.bin' if multifile else selected
            paths = [selected_name + path[len(name.decode()):] for path in paths]
        metainfo = root / 'share.torrent'; metainfo.write_bytes(bencode({b'info': info}))
        command = dict(id='original-seed', input=str(metainfo), destination=str(originals),
                       contentRoot=str(originals), filePaths=paths, seedOnly=True)
        snapshot = {str(file.relative_to(originals)): file.read_bytes() for file in originals.rglob('*') if file.is_file()}
        helper, port = start(binary, state)
        try:
            helper.send(type='add', **command)
            helper.wait(lambda event: event['type'] == 'done')
            # Preference changes must not make an original seed auto-managed;
            # libtorrent may otherwise clear upload mode after a disk retry.
            helper.send(type='configure', listenPort=port, networkInterface='127.0.0.1',
                transportMode='tcp', encryptionMode='disabled', dhtEnabled=False,
                peerExchangeEnabled=False, localPeerDiscoveryEnabled=False, upnpEnabled=False,
                natpmpEnabled=False, queueingEnabled=True)
            received = receive_payload(port, hashlib.sha1(bencode(info)).digest(), len(payload))
            assert received == payload
            for offset in range(0, len(payload), 16384):
                assert hashlib.sha1(received[offset:offset+16384]).digest() == hashlib.sha1(payload[offset:offset+16384]).digest()
            helper.send(type='stop', id=command['id'])
            helper.wait(lambda event: event['type'] == 'seedingStopped')
        finally:
            helper.close()
        with sqlite3.connect(state / 'resume-state.sqlite3') as database:
            saved = database.execute('SELECT current_blob FROM resume_snapshots WHERE torrent_id=?',
                                     (command['id'],)).fetchone()[0]
            resume, _ = bdecode(saved)
            assert resume[b'upload_mode'] == 1 and resume[b'auto_managed'] == 0, resume
        # Preserve the size while invalidating a piece; saved state must never hide this change.
        damaged = bytearray(first.read_bytes()); damaged[0] ^= 0xff; first.write_bytes(damaged)
        helper, _ = start(binary, state)
        try:
            helper.send(type='resume', **command)
            failure = wait_failure(helper)
            assert 'piece hashes' in failure['message'], failure
            helper.send(type='cancel', id=command['id'], destroyData=True)
            helper.wait(lambda event: event['type'] == 'cancelled')
        finally:
            helper.close()
        after = {str(file.relative_to(originals)): file.read_bytes() for file in originals.rglob('*') if file.is_file()}
        snapshot[str(first.relative_to(originals))] = bytes(damaged)
        assert after == snapshot, 'Seeding/removal changed or created original files'
        # A missing original must be rejected before initializing storage.
        first.unlink()
        helper, _ = start(binary, state)
        try:
            helper.send(type='add', **command)
            failure = wait_failure(helper)
            assert 'missing' in failure['message'], failure
        finally:
            helper.close()
        assert not first.exists(), 'Missing original was recreated'
        print(('Folder' if multifile else 'Single file') + (' (renamed source)' if renamed else '')
              + ': verified upload, stale-resume rejection and originals retained', flush=True)


if __name__ == '__main__':
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    exercise(binary, False)
    exercise(binary, True)
    exercise(binary, False, renamed=True)
    exercise(binary, True, renamed=True)
