"""Create every format, independently check hashes, and transfer/recheck originals."""
import base64
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

from ContentLayoutIntegrationTests import bencode, bdecode
from OriginalSeedingIntegrationTests import start, wait_failure


def merkle_root(payload, piece_size):
    hashes = [hashlib.sha256(payload[offset:offset + 16384]).digest()
              for offset in range(0, len(payload), 16384)]
    count = 1
    while count < max(len(hashes), min(piece_size // 16384, len(hashes))):
        count *= 2
    hashes += [bytes(32)] * (count - len(hashes))
    while len(hashes) > 1:
        hashes = [hashlib.sha256(hashes[index] + hashes[index + 1]).digest()
                  for index in range(0, len(hashes), 2)]
    return hashes[0]


def exercise(binary, format, folder):
    with tempfile.TemporaryDirectory(prefix='torravia-create-') as temporary:
        root = pathlib.Path(temporary)
        originals = root / 'originals'; originals.mkdir()
        source = originals / ('Shared' if folder else 'sample.bin')
        payloads = {'a.bin': bytes(index % 251 for index in range(10000)),
                    'empty.bin': b'', 'nested/b.bin': bytes(index % 239 for index in range(40123))} if folder else {
                    'sample.bin': bytes(index % 251 for index in range(50123))}
        files = []
        for path, payload in payloads.items():
            target = source / path if folder else source
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            files.append({'path': str(target.relative_to(originals)), 'size': len(payload)})
        request = dict(format=format, root=str(originals), files=files, pieceLength=16384,
                       trackers=['http://127.0.0.1:1/announce'], comment='Integration test', private=True)
        created = subprocess.run([binary, '--create-torrent'], input=json.dumps(request) + '\n',
                                 text=True, capture_output=True, check=True, timeout=30)
        events = [json.loads(line) for line in created.stdout.splitlines()]
        data = base64.b64decode(events[-1]['data'])
        metadata, _ = bdecode(data)
        info = metadata[b'info']
        assert (b'pieces' in info) == (format != 'v2')
        assert (info.get(b'meta version') == 2) == (format != 'v1')
        assert info[b'private'] == 1
        if format != 'v2':
            logical = b''
            if b'files' in info:
                for file in info[b'files']:
                    path = '/'.join(part.decode() for part in file[b'path'])
                    logical += bytes(file[b'length']) if b'p' in file.get(b'attr', b'') else payloads[path]
            else:
                logical = payloads['sample.bin']
            assert info[b'pieces'] == b''.join(hashlib.sha1(logical[offset:offset + 16384]).digest()
                                             for offset in range(0, len(logical), 16384))
        if format != 'v1':
            for path, payload in payloads.items():
                node = info[b'file tree']
                for part in path.split('/'):
                    node = node[part.encode()]
                attributes = node[b'']
                assert attributes[b'length'] == len(payload)
                if payload:
                    assert attributes[b'pieces root'] == merkle_root(payload, 16384)
        # Remap a renamed source without supplying virtual padding entries.
        selected = originals / ('Renamed' if folder else 'renamed.bin')
        source.rename(selected)
        paths = [str((selected / path if folder else selected).relative_to(originals)) for path in payloads]
        metainfo = root / 'share.torrent'; metainfo.write_bytes(data)
        seed_state = root / 'seed-state'; seed_state.mkdir()
        download_state = root / 'download-state'; download_state.mkdir()
        destination = root / 'downloads'; destination.mkdir()
        command = dict(id='seed', input=str(metainfo), destination=str(originals),
                       contentRoot=str(originals), filePaths=paths, seedOnly=True)
        seed, port = start(binary, seed_state)
        downloader, _ = start(binary, download_state)
        try:
            seed.send(type='add', **command)
            added = seed.wait(lambda event: event['type'] == 'added')
            assert added['length'] == sum(map(len, payloads.values()))
            assert sum(not file.get('isPadding', False) for file in added['files']) == len(payloads)
            seed.wait(lambda event: event['type'] == 'done')
            downloader.send(type='add', id='download', input=str(metainfo), destination=str(destination))
            downloader.wait(lambda event: event['type'] == 'added')
            downloader.send(type='addPeer', id='download', address=f'127.0.0.1:{port}')
            downloader.wait(lambda event: event['type'] == 'done')
            for path, payload in payloads.items():
                target = destination / 'Shared' / path if folder else destination / 'sample.bin'
                actual = target.read_bytes()
                if actual != payload:
                    downloader.close()
                    raise AssertionError((format, str(target), 'bytes at completion', len(actual),
                                          'expected', len(payload), 'matches after shutdown', target.read_bytes() == payload))
            seed.send(type='stop', id='seed')
            seed.wait(lambda event: event['type'] == 'seedingStopped')
        finally:
            downloader.close()
            seed.close()
        first = selected / 'a.bin' if folder else selected
        damaged = bytearray(first.read_bytes()); damaged[0] ^= 255; first.write_bytes(damaged)
        seed, _ = start(binary, seed_state)
        try:
            seed.send(type='resume', **command)
            assert 'piece hashes' in wait_failure(seed)['message']
            seed.send(type='cancel', id='seed', destroyData=True)
            seed.wait(lambda event: event['type'] == 'cancelled')
        finally:
            seed.close()
        assert first.read_bytes() == bytes(damaged)
        actual_paths = {str(path.relative_to(selected)) for path in selected.rglob('*') if path.is_file()} if folder else {'sample.bin'}
        assert actual_paths == set(payloads), 'Padding or unwanted files were created in the originals'
        print(f'{format} {"folder" if folder else "file"}: hashes, renamed-source transfer, restart corruption rejection and safe removal passed', flush=True)


if __name__ == '__main__':
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    for format in ('v1', 'v2', 'hybrid'):
        for folder in (False, True):
            exercise(binary, format, folder)
