"""Compare two Torravia releases using isolated, hash-verified transfers.

Separates first payload, first reported MB/s, and wire transfer duration. Tests
both an injected peer and a loopback tracker, alternating client order. Each
run uses fresh state and downloads; no public torrent or swarm is contacted.
Performance measurements are reported, not asserted as deterministic tests.
"""
import argparse
import asyncio
import hashlib
import http.server
import json
import pathlib
import socket
import statistics
import struct
import threading

from RequestWindowIntegrationTests import Fixture, bencode, run


class LocalTracker:
    def __init__(self, peer_port):
        self.announces = 0
        tracker = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                tracker.announces += 1
                body = bencode({b'interval': 1800, b'min interval': 1800,
                                b'peers': socket.inet_aton('127.0.0.1')
                                + struct.pack('!H', peer_port)})
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/announce'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def summarize(rows):
    summary = {}
    for mode in sorted({row['mode'] for row in rows}):
        summary[mode] = {}
        for client in ['baseline', 'current']:
            selected = [r for r in rows if r['mode'] == mode and r['client'] == client]
            metrics = {}
            for key in ['first_payload_seconds', 'first_reported_MBps_seconds',
                        'wire_seconds', 'seconds', 'MBps']:
                values = [r[key] for r in selected if r[key] is not None]
                metrics[key] = ({'median': round(statistics.median(values), 3),
                                 'min': min(values), 'max': max(values)} if values else None)
            summary[mode][client] = metrics
    return summary


async def main(args):
    binaries = {'baseline': args.baseline.resolve(), 'current': args.current.resolve()}
    for binary in binaries.values():
        if not binary.is_file():
            raise FileNotFoundError(binary)
    rows = []
    for mode in args.modes:
        for repeat in range(args.repeats):
            order = ['baseline', 'current'] if repeat % 2 == 0 else ['current', 'baseline']
            for client in order:
                fixture = Fixture(count=args.pieces, delay=args.delay, remote_limit=args.remote_limit)
                server = await asyncio.start_server(fixture.seed, '127.0.0.1', 0)
                tracker = None
                async with server:
                    port = server.sockets[0].getsockname()[1]
                    try:
                        if mode == 'tracker':
                            tracker = LocalTracker(port)
                        result = await asyncio.to_thread(run, binaries[client], port, fixture,
                                                         tracker_url=tracker.url if tracker else None)
                        if tracker:
                            assert tracker.announces > 0, 'The local tracker was never contacted'
                            result['tracker_announces'] = tracker.announces
                    finally:
                        if tracker:
                            await asyncio.to_thread(tracker.close)
                assert fixture.max_pending <= args.remote_limit, 'Remote request limit exceeded'
                result.update(client=client, mode=mode, repeat=repeat + 1,
                              bytes=fixture.count * len(fixture.piece),
                              delay=args.delay, remote_limit=args.remote_limit)
                rows.append(result)
                print(json.dumps(result), flush=True)
    report = {'binaries': {name: {'path': str(binary),
                                  'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
                           for name, binary in binaries.items()},
              'notes': ['Every piece is hash verified; state and payloads are temporary.',
                        'First reported MB/s includes engine smoothing and status sampling.',
                        'Wire duration excludes startup and completion notification latency.',
                        'Loopback measurements do not establish public swarm startup performance.'],
              'runs': rows, 'summary': summarize(rows)}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('SUMMARY', json.dumps(report['summary']), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=pathlib.Path)
    parser.add_argument('current', type=pathlib.Path)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--pieces', type=int, default=256)
    parser.add_argument('--delay', type=float, default=0.25)
    parser.add_argument('--remote-limit', type=int, default=512)
    parser.add_argument('--modes', nargs='+', choices=['manual', 'tracker'], default=['manual', 'tracker'])
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.repeats <= 0 or args.pieces <= 0 or args.pieces % 8:
        parser.error('Repeats must be positive and pieces a positive multiple of 8')
    if args.delay < 0 or not 1 <= args.remote_limit <= 65_535:
        parser.error('Delay must be nonnegative and remote limit between 1 and 65535')
    asyncio.run(main(args))
