"""Validate both universal slices and exercise the host's native helper slice.

Usage: python3 UniversalCompatibilityTests.py [app-bundle] [--all-architectures] [--require-all]
Additional runtime architectures are opt-in. Intel tests on Apple silicon use
Rosetta, which can trigger macOS 27's macOS 28 compatibility notification.
These checks do not replace testing on physical Intel hardware or macOS Sonoma.
"""
import argparse
import pathlib
import platform
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile


ARCHITECTURES = ('arm64', 'x86_64')
MINIMUM_OS = (14, 0)
MACHO_MAGIC = {bytes.fromhex(value) for value in
              ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
               'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}


def validate_bundle(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert tuple(map(int, info['LSMinimumSystemVersion'].split('.'))) <= MINIMUM_OS, info
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    checked = 0
    for path in sorted(app.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in MACHO_MAGIC:
            continue
        arches = set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())
        assert arches == set(ARCHITECTURES), (path, arches)
        build = subprocess.check_output(['vtool', '-show-build', str(path)], text=True)
        targets = re.findall(r'minos\s+([\d.]+)', build)
        assert len(targets) == 2 and all(tuple(map(int, value.split('.'))) <= MINIMUM_OS
                                      for value in targets), (path, targets)
        links = subprocess.check_output(['otool', '-L', str(path)], text=True)
        dependencies = [line.strip().split(' (compatibility version', 1)[0]
                        for line in links.splitlines() if ' (compatibility version' in line]
        assert all(value.startswith(('@rpath/', '/usr/lib/', '/System/Library/'))
                   for value in dependencies), (path, dependencies)
        checked += 1
        print(str(path.relative_to(app)) + ': arm64 + x86_64, macOS <= 14.0', flush=True)
    assert checked >= 5, 'Missing expected app/helper/library binaries'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', default='/Applications/Torravia.app')
    parser.add_argument('--all-architectures', action='store_true',
                        help='Opt in to both runtime architectures, including Rosetta on Apple silicon')
    parser.add_argument('--require-all', action='store_true',
                        help='Opt in to both runtime architectures and fail if either cannot execute')
    args = parser.parse_args()
    app = pathlib.Path(args.app).resolve()
    validate_bundle(app)
    helper = app / 'Contents/MacOS/TorrentNativeHelper'
    tests = pathlib.Path(__file__).resolve().parent
    # Detect hardware rather than Python's process architecture: Python itself
    # may have been launched through Rosetta on an Apple silicon Mac.
    apple_silicon = subprocess.run(['sysctl', '-n', 'hw.optional.arm64'],
                                  capture_output=True, text=True).stdout.strip() == '1'
    native = 'arm64' if apple_silicon else platform.machine()
    if native not in ARCHITECTURES:
        raise RuntimeError('Unsupported host architecture: ' + native)
    architectures = ARCHITECTURES if args.all_architectures or args.require_all else (native,)
    for architecture in ARCHITECTURES:
        if architecture not in architectures:
            print('Runtime checks skipped: ' + architecture + ' is not native; '
                  'both slices were validated without executing Rosetta', flush=True)
    with tempfile.TemporaryDirectory(prefix='torravia-universal-tests-') as temporary:
        for architecture in architectures:
            available = subprocess.run(['arch', '-' + architecture, '/usr/bin/true'],
                                       stderr=subprocess.DEVNULL).returncode == 0
            if not available:
                print('Runtime checks skipped: ' + architecture + ' cannot execute on this host', flush=True)
                if args.require_all:
                    raise RuntimeError('Both architectures must be executable with --require-all')
                continue
            wrapper = pathlib.Path(temporary) / ('helper-' + architecture)
            wrapper.write_text('#!/bin/sh\nexec /usr/bin/arch -' + architecture + ' ' + shlex.quote(str(helper)) + ' "$@"\n')
            wrapper.chmod(0o700)
            for test in ['RequestWindowIntegrationTests.py', 'ResumeProgressIntegrationTests.py', 'RetiredTrackerTests.py',
                         'OriginalSeedingIntegrationTests.py', 'TorrentCreationIntegrationTests.py', 'SeedingLimitsIntegrationTests.py']:
                print(architecture + ': ' + test, flush=True)
                subprocess.run([sys.executable, str(tests / test), str(wrapper)], check=True)
    print('Universal bundle and requested architecture runtime checks passed', flush=True)


if __name__ == '__main__':
    main()
