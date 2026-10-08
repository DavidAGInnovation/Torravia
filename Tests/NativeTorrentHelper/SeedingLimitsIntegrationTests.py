"""Exercise native seeding policies against verified private loopback content."""
import hashlib
import pathlib
import queue
import sys
import tempfile
import time

from ContentLayoutIntegrationTests import bencode
from OriginalSeedingIntegrationTests import start, receive_payload


def exercise(binary, limit, action):
    with tempfile.TemporaryDirectory(prefix='torravia-seeding-limits-') as temporary:
        root = pathlib.Path(temporary)
        state = root / 'state'; state.mkdir()
        originals = root / 'originals'; originals.mkdir()
        payload = bytes(index % 251 for index in range(50123))
        content = originals / 'sample.bin'; content.write_bytes(payload)
        info = {b'name': b'sample.bin', b'length': len(payload), b'piece length': 16384,
                b'private': 1, b'pieces': b''.join(hashlib.sha1(payload[i:i+16384]).digest()
                                                for i in range(0, len(payload), 16384))}
        torrent = root / 'share.torrent'; torrent.write_bytes(bencode({b'info': info}))
        command = dict(id='policy-seed', input=str(torrent), destination=str(originals),
                       contentRoot=str(originals), filePaths=['sample.bin'], seedOnly=True)
        helper, port = start(binary, state)
        try:
            helper.send(type='add', **command)
            helper.wait(lambda e: e['type'] == 'done')
            # Seed a real peer and verify every piece before exercising the policy.
            received = receive_payload(port, hashlib.sha1(bencode(info)).digest(), len(payload))
            assert received == payload
            for offset in range(0, len(payload), 16384):
                assert hashlib.sha1(received[offset:offset+16384]).digest() == hashlib.sha1(payload[offset:offset+16384]).digest()
            helper.send(type='pause', id=command['id'])
            helper.wait(lambda e: e['type'] == 'paused')
            # Restored active counters near the threshold make this test fast.
            helper.send(type='setShareRatioPolicy', id=command['id'], limit=0, action=action,
                        seedingTimeLimit=1 if limit == 'time' else 0,
                        inactiveSeedingTimeLimit=1 if limit == 'inactivity' else 0,
                        seedingSeconds=59 if limit == 'time' else 0,
                        inactiveSeconds=59 if limit == 'inactivity' else 0)
            baseline = helper.wait(lambda e: e['type'] == 'progress'
                                  and e.get('seedingTimeSeconds', 0) >= (59 if limit == 'time' else 0)
                                  and e.get('inactiveSeedingTimeSeconds', 0) >= (59 if limit == 'inactivity' else 0))
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    event = helper.events.get(timeout=0.2)
                except queue.Empty:
                    continue
                assert event['type'] not in ('seedingLimitReached', 'cancelled'), event
                if event['type'] == 'progress':
                    assert event['seedingTimeSeconds'] == baseline['seedingTimeSeconds'], event
                    assert event['inactiveSeedingTimeSeconds'] == baseline['inactiveSeedingTimeSeconds'], event
            # Restart with durable resume data and restore the app's saved counters.
            saved_seconds = baseline['seedingTimeSeconds']
            saved_inactive = baseline['inactiveSeedingTimeSeconds']
            helper.close()
            helper, port = start(binary, state)
            helper.send(type='resume', **command)
            helper.wait(lambda e: e['type'] == 'done')
            helper.send(type='pause', id=command['id'])
            helper.wait(lambda e: e['type'] == 'paused')
            helper.send(type='setShareRatioPolicy', id=command['id'], limit=0, action=action,
                        seedingTimeLimit=1 if limit == 'time' else 0,
                        inactiveSeedingTimeLimit=1 if limit == 'inactivity' else 0,
                        seedingSeconds=saved_seconds, inactiveSeconds=saved_inactive)
            restored = helper.wait(lambda e: e['type'] == 'progress'
                                   and e.get('seedingTimeSeconds', 0) >= saved_seconds
                                   and e.get('inactiveSeedingTimeSeconds', 0) >= saved_inactive)
            assert restored['inactiveSeedingTimeSeconds'] == saved_inactive, restored
            helper.send(type='resume', **command)
            reached = helper.wait(lambda e: e['type'] == ('seedingLimitReached' if action == 1 else 'cancelled'))
            if action == 1:
                assert reached['reason'] == limit and reached['action'] == 'pause', reached
                # Resuming must not silently bypass an enabled, already-reached limit.
                helper.send(type='resume', **command)
                repeated = helper.wait(lambda e: e['type'] == 'seedingLimitReached')
                assert repeated['reason'] == limit, repeated
                # A new verified completion must precede the policy pause,
                # otherwise the UI completion update clears the stop reason.
                helper.send(type='forceRecheck', id=command['id'])
                helper.send(type='resume', **command)
                completion_seen = False
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    event = helper.events.get(timeout=5)
                    if event['type'] == 'done':
                        completion_seen = True
                    if event['type'] == 'seedingLimitReached':
                        assert completion_seen, 'Limit pause arrived before verified completion'
                        assert event['reason'] == limit, event
                        break
                else:
                    raise AssertionError('Rechecked torrent did not enforce the reached limit')
            assert content.read_bytes() == payload, 'Policy changed original files'
        finally:
            helper.close()
        print(f'PASS: {limit} limit, action {action}, pause exclusion, restart restoration, hash-verified upload, originals kept', flush=True)


def upload_resets_inactivity(binary):
    with tempfile.TemporaryDirectory(prefix='torravia-inactivity-reset-') as temporary:
        root = pathlib.Path(temporary)
        state = root / 'state'; state.mkdir()
        originals = root / 'originals'; originals.mkdir()
        payload = bytes(index % 251 for index in range(50123))
        content = originals / 'sample.bin'; content.write_bytes(payload)
        info = {b'name': b'sample.bin', b'length': len(payload), b'piece length': 16384,
                b'private': 1, b'pieces': b''.join(hashlib.sha1(payload[i:i+16384]).digest()
                                                for i in range(0, len(payload), 16384))}
        torrent = root / 'share.torrent'; torrent.write_bytes(bencode({b'info': info}))
        helper, port = start(binary, state)
        try:
            helper.send(type='add', id='idle-reset', input=str(torrent), destination=str(originals),
                        contentRoot=str(originals), filePaths=['sample.bin'], seedOnly=True)
            helper.wait(lambda e: e['type'] == 'done')
            helper.send(type='setShareRatioPolicy', id='idle-reset', action=0, limit=0,
                        inactiveSeedingTimeLimit=1, inactiveSeconds=30)
            helper.wait(lambda e: e['type'] == 'progress' and e.get('inactiveSeedingTimeSeconds', 0) >= 30)
            received = receive_payload(port, hashlib.sha1(bencode(info)).digest(), len(payload))
            assert received == payload
            for offset in range(0, len(payload), 16384):
                assert hashlib.sha1(received[offset:offset+16384]).digest() == hashlib.sha1(payload[offset:offset+16384]).digest()
            sample = helper.wait(lambda e: e['type'] == 'progress' and e.get('uploaded', 0) >= len(payload)
                                 and e.get('inactiveSeedingTimeSeconds', 30) < 5)
            assert sample['seedingTimeSeconds'] >= 0
        finally:
            helper.close()
        print('PASS: real hash-verified payload upload resets saved inactivity', flush=True)


if __name__ == '__main__':
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    upload_resets_inactivity(binary)
    for limit in ('time', 'inactivity'):
        for action in (1, 2):
            exercise(binary, limit, action)
