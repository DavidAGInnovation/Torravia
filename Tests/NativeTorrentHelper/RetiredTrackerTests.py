"""Check the helper's real announce list and fast-resume retirement.

Usage: python3 Tests/NativeTorrentHelper/RetiredTrackerTests.py <helper-binary>
All torrent state and payload files are isolated in a temporary directory.
"""
import json
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse


def check(helper, directory):
    process = subprocess.Popen(
        [helper], cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )
    events = queue.Queue()

    def read_events():
        for line in process.stdout:
            events.put(json.loads(line))

    threading.Thread(target=read_events, daemon=True).start()

    def send(command):
        process.stdin.write(json.dumps(command) + "\n")
        process.stdin.flush()

    def snapshot():
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            send({"type": "getDiscovery", "id": "retirement-test"})
            try:
                event = events.get(timeout=0.2)
            except queue.Empty:
                continue
            if event["type"] == "error":
                raise AssertionError(event)
            if event["type"] == "discovery":
                return event
        raise AssertionError("Timed out waiting for tracker list")

    retired = "udp://explodie.org:6969/announce"
    retained = "udp://127.0.0.1:59999/announce"
    try:
        assert events.get(timeout=5)["type"] == "ready"
        send({"type": "configure", "dhtEnabled": False,
              "localPeerDiscoveryEnabled": False, "upnpEnabled": False,
              "natpmpEnabled": False, "additionalTrackerURLs": [retired],
              "adaptiveTrackerURLs": [retired]})
        magnet = "magnet:?" + urllib.parse.urlencode([
            ("xt", "urn:btih:0123456789abcdef0123456789abcdef01234567"),
            ("tr", retired), ("tr", retained),
        ])
        send({"type": "add", "id": "retirement-test", "input": magnet,
              "destination": directory})
        result = snapshot()
        assert [t["url"] for t in result["trackers"]] == [retained], result
        # Configuration refresh must not add the retired endpoint again.
        send({"type": "configure", "dhtEnabled": False,
              "additionalTrackerURLs": [retired]})
        result = snapshot()
        assert [t["url"] for t in result["trackers"]] == [retained], result
    finally:
        send({"type": "shutdown"})
        process.stdin.close()
        process.wait(timeout=15)
        assert process.returncode == 0


with tempfile.TemporaryDirectory(prefix="torravia-retirement-") as directory:
    helper = str(pathlib.Path(sys.argv[1]).resolve())
    check(helper, directory)
    check(helper, directory)  # Reload the saved fast-resume snapshot.
print("Tracker retirement verified for magnets, configuration, and fast-resume")
