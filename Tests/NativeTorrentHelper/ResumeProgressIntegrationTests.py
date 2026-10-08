"""Verify partial progress across a paused helper restart and a real recheck.

Usage: python3 ResumeProgressIntegrationTests.py <helper-binary>
Uses private local metainfo, disables discovery, and isolates all state.
"""
import hashlib
import json
import pathlib
import queue
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
        return b'd' + b''.join(bencode(k) + bencode(v)
                              for k, v in sorted(value.items())) + b'e'
    raise TypeError(type(value))


class Helper:
    def __init__(self, binary, directory):
        self.process = subprocess.Popen(
            [binary], cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True)
        self.events = queue.Queue()

        def read_events():
            for line in self.process.stdout:
                self.events.put(json.loads(line))

        threading.Thread(target=read_events, daemon=True).start()
        self.wait(lambda event: event['type'] == 'ready')
        self.send(type='configure', networkInterface='127.0.0.1',
                  encryptionMode='disabled', dhtEnabled=False,
                  peerExchangeEnabled=False, localPeerDiscoveryEnabled=False,
                  upnpEnabled=False, natpmpEnabled=False, queueingEnabled=False)

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()

    def wait(self, predicate):
        deadline = time.monotonic() + 30
        seen = []
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            assert event['type'] != 'error', event
            seen.append(event)
            if predicate(event):
                return event
        raise AssertionError(f'Timed out: {seen[-5:]}')

    def verified(self, fraction, downloaded):
        event = self.wait(lambda event: event['type'] == 'progress'
                          and event.get('isProgressReady') is True
                          and abs(event['progress'] - fraction) < 0.00001)
        assert event['downloaded'] == downloaded, event

    def close(self):
        self.send(type='shutdown')
        self.process.stdin.close()
        self.process.wait(timeout=15)
        assert self.process.returncode == 0


binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='torravia-resume-progress-') as root:
    directory = pathlib.Path(root)
    piece = b'\xab' * (1024 * 1024)
    info = {b'name': b'partial.bin', b'length': 16 * len(piece),
            b'piece length': len(piece), b'private': 1,
            b'pieces': hashlib.sha1(piece).digest() * 16}
    torrent = directory / 'partial.torrent'
    torrent.write_bytes(bencode({b'info': info}))
    payload = directory / 'partial.bin'
    payload.write_bytes(piece * 12 + b'\0' * (4 * len(piece)))
    command = dict(id='resume-progress', input=str(torrent), destination=root)

    helper = Helper(binary, root)
    try:
        helper.send(type='add', **command)
        helper.verified(0.75, 12 * len(piece))
        helper.send(type='pause', id=command['id'])
        helper.wait(lambda event: event['type'] == 'paused')
    finally:
        helper.close()

    # A fresh process loads the same fast-resume data after the idle shutdown.
    helper = Helper(binary, root)
    try:
        helper.send(type='resume', **command)
        helper.verified(0.75, 12 * len(piece))
        with payload.open('r+b') as stream:
            stream.write(b'\0' * (4 * len(piece)))
        helper.send(type='forceRecheck', id=command['id'])
        helper.verified(0.5, 8 * len(piece))
        with payload.open('r+b') as stream:
            stream.write(b'\0' * (12 * len(piece)))
        helper.send(type='forceRecheck', id=command['id'])
        helper.verified(0, 0)
    finally:
        helper.close()

print('Verified 75% after pause/restart; damaged-piece rechecks correctly report 50% and 0%')
