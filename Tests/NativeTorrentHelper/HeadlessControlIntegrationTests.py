#!/usr/bin/env python3
"""Installed macOS headless lifecycle smoke test. Close Torravia first.

Uses the existing queue without adding/removing torrents or changing preferences.
"""
import http.client
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time
import urllib.parse

BINARY = '/Applications/Torravia.app/Contents/MacOS/Torravia'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def run_mode(extra, expected_frontend=None):
    port = free_port()
    token_directory = tempfile.TemporaryDirectory(prefix='Torravia-token-test-', dir=Path.home() / 'Downloads')
    explicit_token = Path(token_directory.name) / 'access-token'
    process = subprocess.Popen([BINARY, '--headless', '--webui-port', str(port), '--token-file', str(explicit_token), *extra],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    token_path = None
    children = []
    try:
        buffer = b''
        deadline = time.monotonic() + 25
        lines = []
        while time.monotonic() < deadline and token_path is None:
            if process.poll() is not None:
                raise AssertionError('Headless startup failed: ' + process.stderr.read().decode())
            ready, _, _ = select.select([process.stdout], [], [], 0.2)
            if ready:
                buffer += os.read(process.stdout.fileno(), 65536)
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    line = line.decode()
                    lines.append(line)
                    if line.startswith('Access token file: '):
                        token_path = Path(line.removeprefix('Access token file: '))
        assert token_path, 'Timed out waiting for ready state'
        address = next(line.removeprefix('Torravia headless ready: ') for line in lines
                       if line.startswith('Torravia headless ready: '))
        endpoint = urllib.parse.urlsplit(address)
        assert endpoint.hostname == '127.0.0.1'
        assert token_path.stat().st_mode & 0o777 == 0o600
        token = token_path.read_text().strip()

        def request(path, authenticated=False, origin=None):
            connection_type = http.client.HTTPSConnection if endpoint.scheme == 'https' else http.client.HTTPConnection
            connection = connection_type(endpoint.hostname, endpoint.port, timeout=5)
            headers = {}
            if authenticated:
                headers['Authorization'] = 'Bearer ' + token
            if origin:
                headers['Origin'] = origin
            connection.request('GET', path, headers=headers)
            response = connection.getresponse()
            body = response.read()
            status = response.status
            connection.close()
            return status, body

        assert request('/api/app')[0] == 401
        status, body = request('/api/app', True)
        assert status == 200
        app = json.loads(body)
        assert app['headless'] is True
        assert app['alternativeBrowserUI'] is bool(expected_frontend)
        assert request('/api/app', True, 'https://evil.example')[0] == 403
        status, body = request('/')
        assert status == 200
        if expected_frontend:
            assert body == expected_frontend
            assert request('/image.png')[1] == bytes([0, 255, 128, 65])
            assert request('/../secret.json')[0] == 404
            assert request('/%2e%2e/secret.json')[0] == 404
            assert request('/escape.json')[0] == 404
            assert request('/.private.json')[0] == 404
            assert request('/web.js')[0] == 404
        else:
            assert b'Connect to your Mac' in body
        conflict = subprocess.run([BINARY, '--headless', '--webui-port', str(free_port())],
                                  capture_output=True, timeout=8)
        assert conflict.returncode != 0
        assert b'already running' in conflict.stderr
        result = subprocess.run(['pgrep', '-P', str(process.pid)], capture_output=True, text=True)
        children = [int(value) for value in result.stdout.split()]
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=20) == 0
        assert not token_path.exists(), 'Orderly shutdown left the token file'
        for child in children:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                continue
            raise AssertionError(f'Native helper {child} survived shutdown')
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()
        process.stderr.close()
        token_directory.cleanup()


def main():
    help_result = subprocess.run([BINARY, '--help'], capture_output=True, timeout=5)
    assert help_result.returncode == 0 and b'--headless' in help_result.stdout
    invalid = subprocess.run([BINARY, '--headless', '--webui-port', '0'], capture_output=True, timeout=5)
    assert invalid.returncode != 0
    run_mode([])
    print('PASS: built-in headless API, private token, single instance, graceful helper shutdown')
    downloads = Path.home() / 'Downloads'
    with tempfile.TemporaryDirectory(prefix='Torravia-headless-test-', dir=downloads) as temporary:
        root = Path(temporary)
        site = root / 'site'
        site.mkdir()
        frontend = b'<!doctype html><title>Alternative interface test</title>'
        (site / 'index.html').write_bytes(frontend)
        (site / 'image.png').write_bytes(bytes([0, 255, 128, 65]))
        (root / 'secret.json').write_text('private')
        (site / '.private.json').write_text('private')
        (site / 'escape.json').symlink_to(root / 'secret.json')
        run_mode(['--webui-directory', str(site)], frontend)
    print('PASS: alternative assets, binary integrity, authentication, path confinement')


if __name__ == '__main__':
    main()
