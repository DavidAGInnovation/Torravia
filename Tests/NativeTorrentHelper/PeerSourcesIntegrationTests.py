"""Verify peer discovery labels through real incoming and outgoing connections.

Usage: python3 PeerSourcesIntegrationTests.py <helper>
Transfers private, hash-verified payloads over loopback and removes all state.
"""
import asyncio
import hashlib
import json
import pathlib
import re
import socket
import sys
import tempfile

from ContentLayoutIntegrationTests import Helper
from RequestWindowIntegrationTests import Fixture, bencode


def listening_port():
    # Configuration accepts only the application's high-port range.
    for port in range(59000, 60000):
        with socket.socket() as probe:
            try:
                probe.bind(('127.0.0.1', port))
                return port
            except OSError:
                continue
    raise AssertionError('No loopback test port available')


def exercise(binary, fixture, incoming, seed_port, loop):
    with tempfile.TemporaryDirectory(prefix='torravia-peer-sources-') as root:
        directory = pathlib.Path(root)
        metainfo = directory / 'private.torrent'
        metainfo.write_bytes(bencode({b'info': fixture.info}))
        helper = Helper(binary, root)
        port = listening_port()
        try:
            helper.send(type='configure', listenPort=port,
                        networkInterface='127.0.0.1', transportMode='tcp',
                        encryptionMode='disabled', dhtEnabled=False,
                        peerExchangeEnabled=False, localPeerDiscoveryEnabled=False,
                        upnpEnabled=False, natpmpEnabled=False, queueingEnabled=False)
            helper.wait(lambda e: e['type'] == 'networkStatus'
                        and e['isListening'] and e['listenPort'] == port)
            helper.send(type='add', id='source-test', input=str(metainfo), destination=root)
            helper.wait(lambda e: e['type'] == 'added')
            helper.send(type='setPeerDetails', id='source-test', enabled=True)
            if incoming:
                async def connect():
                    reader, writer = await asyncio.open_connection('127.0.0.1', port)
                    asyncio.create_task(fixture.seed(reader, writer, incoming=True))

                asyncio.run_coroutine_threadsafe(connect(), loop).result(timeout=5)
            else:
                helper.send(type='addPeer', id='source-test', address=f'127.0.0.1:{seed_port}')

            snapshot = helper.wait(lambda e: e['type'] == 'peers' and e['peers'])
            assert len(snapshot['peers']) == 1, snapshot
            peer = snapshot['peers'][0]
            summary = {key: peer[key] for key in ('direction', 'sources', 'client')}
            print(json.dumps(summary), flush=True)
            assert peer['direction'] == ('Incoming' if incoming else 'Outgoing'), summary
            assert peer['sources'] == (['Incoming'] if incoming else ['Manual']), summary
            helper.wait(lambda e: e['type'] == 'done')
            with (directory / 'window-test.bin').open('rb') as payload:
                expected = hashlib.sha1(fixture.piece).digest()
                for _ in range(fixture.count):
                    assert hashlib.sha1(payload.read(len(fixture.piece))).digest() == expected
                assert payload.read(1) == b''
        finally:
            helper.close()


async def main(binary):
    loop = asyncio.get_running_loop()
    for incoming in (True, False):
        fixture = Fixture(count=8, delay=2)
        server = await asyncio.start_server(fixture.seed, '127.0.0.1', 0)
        async with server:
            await asyncio.to_thread(exercise, binary, fixture, incoming,
                                    server.sockets[0].getsockname()[1], loop)
    fixture = Fixture(count=8, delay=2)

    async def web_seed(reader, writer):
        try:
            while True:
                request = await reader.readuntil(b'\r\n\r\n')
                assert request.startswith(b'GET /window-test.bin HTTP/'), request
                match = re.search(rb'(?i)range: bytes=(\d+)-(\d+)', request)
                assert match, request
                start, end = map(int, match.groups())
                data = fixture.piece * fixture.count
                assert 0 <= start <= end < len(data), (start, end)
                body = data[start:end + 1]
                writer.write((f'HTTP/1.1 206 Partial Content\r\nContent-Length: {len(body)}\r\n'
                              f'Content-Range: bytes {start}-{end}/{len(data)}\r\n\r\n').encode())
                await writer.drain()
                # Keep an established HTTP connection alive across multiple
                # peer polls instead of completing between status snapshots.
                for offset in range(0, len(body), 65536):
                    writer.write(body[offset:offset + 65536])
                    await writer.drain()
                    await asyncio.sleep(0.05)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()

    server = await asyncio.start_server(web_seed, '127.0.0.1', 0)
    async with server:
        await asyncio.to_thread(exercise_web_seed, binary, fixture,
                                server.sockets[0].getsockname()[1])
    print('Incoming, manual and web seed labels verified; all transferred piece hashes passed.')


def exercise_web_seed(binary, fixture, port):
    with tempfile.TemporaryDirectory(prefix='torravia-web-source-') as root:
        directory = pathlib.Path(root)
        metainfo = directory / 'private.torrent'
        metainfo.write_bytes(bencode({b'info': fixture.info,
                                     b'url-list': f'http://127.0.0.1:{port}/window-test.bin'.encode()}))
        helper = Helper(binary, root)
        try:
            helper.send(type='add', id='web-source', input=str(metainfo), destination=root)
            helper.wait(lambda e: e['type'] == 'added')
            helper.send(type='setPeerDetails', id='web-source', enabled=True)
            snapshot = helper.wait(lambda e: e['type'] == 'peers' and e['peers'])
            assert len(snapshot['peers']) == 1, snapshot
            assert snapshot['peers'][0]['sources'] == ['Web seed'], snapshot
            print(json.dumps({'sources': snapshot['peers'][0]['sources']}), flush=True)
            helper.wait(lambda e: e['type'] == 'done')
            with (directory / 'window-test.bin').open('rb') as payload:
                for _ in range(fixture.count):
                    assert hashlib.sha1(payload.read(len(fixture.piece))).digest() \
                        == hashlib.sha1(fixture.piece).digest()
                assert payload.read(1) == b''
        finally:
            helper.close()


if __name__ == '__main__':
    asyncio.run(main(str(pathlib.Path(sys.argv[1]).resolve())))
