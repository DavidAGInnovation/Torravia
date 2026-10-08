"""Vendor the latest stable upstream libtorrent and its matching build headers.

Normal builds use a release check cached for at most five minutes. --refresh
forces an upstream check; --check reports status without modifying Vendor.
An unavailable release or incompatible package fails instead of using an old
engine silently. Previous dependencies are retained under .build/dependencies.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'Vendor'
WORK = ROOT / '.build/dependencies/libtorrent'
API = 'https://api.github.com/repos/arvidn/libtorrent/releases/latest'
DEPLOYMENT_TARGET = '14.0'
ARCHITECTURES = ('arm64', 'x86_64')


def ensure_supported_python():
    # Xcode puts Apple's older Python ahead of Homebrew in PATH. Extraction
    # requires Python 3.12's safe archive filter, including in scheme actions.
    if sys.version_info >= (3, 12):
        return
    for candidate in ['/opt/homebrew/bin/python3', '/usr/local/bin/python3']:
        if not pathlib.Path(candidate).exists():
            continue
        supported = subprocess.run([candidate, '-c',
            'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)']).returncode == 0
        if supported:
            os.execv(candidate, [candidate, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])
    raise RuntimeError('Python 3.12 or newer is required. Install Homebrew Python to rebuild dependencies.')


def version(header):
    text = header.read_text()
    return tuple(int(re.search(r'#define LIBTORRENT_VERSION_' + name + r'\s+(\d+)', text)[1])
                 for name in ['MAJOR', 'MINOR', 'TINY'])


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def github_headers():
    headers = {'User-Agent': 'Torravia-dependency-updater',
               'Accept': 'application/vnd.github+json'}
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    if token:
        headers['Authorization'] = 'Bearer ' + token
    return headers


def latest(refresh):
    cache = WORK / 'upstream-release.json'
    if not refresh and cache.exists() and time.time() - cache.stat().st_mtime < 300:
        release = json.loads(cache.read_text())
    else:
        headers = github_headers()
        request = urllib.request.Request(API, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                release = json.load(response)
        except (urllib.error.URLError, TimeoutError, socket.timeout):
            # macOS curl can recover from connection/address-family failures
            # that stall urllib. Fetch the same official endpoint, with TLS
            # verification and a bounded timeout; invalid data still fails.
            # Headers go over stdin so token values never appear in command
            # arguments or CalledProcessError messages.
            release = json.loads(subprocess.check_output([
                '/usr/bin/curl', '-4', '--fail', '--silent', '--show-error',
                '--max-time', '30', '--header', '@-', API
            ], input=''.join(name + ': ' + value + '\n' for name, value in headers.items()),
                timeout=35, text=True))
        write_json(cache, release)
    match = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)', release['tag_name'])
    if not match or release.get('prerelease') or release.get('draft'):
        raise RuntimeError('Upstream latest release is not a stable semantic version')
    return release, tuple(map(int, match.groups()))


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def architectures(path):
    return set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())


def is_universal(path):
    return architectures(path) == set(ARCHITECTURES)


def library_version(path):
    # Verify the library itself, not just a potentially mismatched header.
    compiler = shutil.which('clang++')
    with tempfile.TemporaryDirectory(dir=WORK) as root:
        root = pathlib.Path(root)
        source = root / 'version.cpp'
        source.write_text('#include <cstdio>\nnamespace libtorrent { const char* version(); }\n'
                          'int main() { std::puts(libtorrent::version()); }\n')
        versions = set()
        for architecture in ARCHITECTURES:
            binary = root / ('version-' + architecture)
            run(compiler, '-arch', architecture, '-mmacosx-version-min=' + DEPLOYMENT_TARGET,
                str(source), str(path), '-o', str(binary),
                '-Wl,-rpath,' + str(path.parent),
                '-Wl,-rpath,' + str(path.parents[2] / 'openssl/lib'), stdout=subprocess.DEVNULL)
            available = subprocess.run(['arch', '-' + architecture, '/usr/bin/true'],
                                       stderr=subprocess.DEVNULL).returncode == 0
            if available:
                versions.add(subprocess.check_output(['arch', '-' + architecture, str(binary)], text=True).strip())
            else:
                print('Runtime version check unavailable on this host for ' + architecture)
        if len(versions) != 1:
            raise RuntimeError('Native library architectures disagree about the engine version')
        return versions.pop()


def installed_is_current(wanted):
    manifest = VENDOR / 'libtorrent/manifest.json'
    library = VENDOR / 'libtorrent/lib/libtorrent-rasterbar.dylib'
    header = VENDOR / 'libtorrent/include/libtorrent/version.hpp'
    if not manifest.exists() or not library.exists() or not header.exists():
        return False
    data = json.loads(manifest.read_text())
    return (version(header) == wanted and data.get('version') == '.'.join(map(str, wanted))
            and data.get('deployment_target') == DEPLOYMENT_TARGET
            and data.get('architectures') == list(ARCHITECTURES)
            and data.get('dylib_sha256') == digest(library)
            and data.get('boost_manifest_sha256') == digest(VENDOR / 'boost/manifest.txt')
            and data.get('boost_version_header_sha256') == digest(VENDOR / 'boost/include/boost/version.hpp')
            and data.get('openssl_dylib_sha256') == {name: digest(VENDOR / 'openssl/lib' / name)
                for name in ['libssl.3.dylib', 'libcrypto.3.dylib']}
            and all(is_universal(path) for path in [library, *[
                VENDOR / 'openssl/lib' / name for name in ['libssl.3.dylib', 'libcrypto.3.dylib']]]))


def supports_deployment_target(package):
    for name in ['libssl.3.dylib', 'libcrypto.3.dylib']:
        library = package / 'lib' / name
        if not library.exists():
            return False
        targets = re.findall(r'minos\s+([\d.]+)', subprocess.check_output(
            ['vtool', '-show-build', str(library)], text=True))
        if not targets or any(tuple(map(int, target.split('.'))) >
                              tuple(map(int, DEPLOYMENT_TARGET.split('.'))) for target in targets):
            return False
    return True


def rebuild_openssl():
    # Rebuild the bundled version, with its matching headers, when lowering the
    # application's minimum OS. Do not relabel an incompatible binary's minOS.
    header = (VENDOR / 'openssl/include/openssl/opensslv.h').read_text()
    match = re.search(r'OPENSSL_VERSION_TEXT\s+"OpenSSL (\d+\.\d+\.\d+) ', header)
    if not match:
        raise RuntimeError('Cannot identify the bundled stable OpenSSL version')
    ssl_version = match[1]
    tag = 'openssl-' + ssl_version
    request = urllib.request.Request('https://api.github.com/repos/openssl/openssl/releases/tags/' + tag,
                                     headers=github_headers())
    with urllib.request.urlopen(request, timeout=30) as response:
        release = json.load(response)
    asset = next((a for a in release['assets'] if a['name'] == tag + '.tar.gz'), None)
    if release.get('prerelease') or release.get('draft') or not asset or not re.fullmatch(
            r'sha256:[0-9a-f]{64}', asset.get('digest') or ''):
        raise RuntimeError('The bundled OpenSSL version has no verified stable source archive')
    root = WORK / (tag + '-macos-' + DEPLOYMENT_TARGET)
    root.mkdir(exist_ok=True)
    archive = root / asset['name']
    if not archive.exists() or 'sha256:' + digest(archive) != asset['digest']:
        with urllib.request.urlopen(asset['browser_download_url'], timeout=60) as response:
            archive.write_bytes(response.read())
    if 'sha256:' + digest(archive) != asset['digest']:
        raise RuntimeError('OpenSSL source archive checksum mismatch')
    installed = root / 'universal'
    if installed.exists():
        shutil.rmtree(installed)
    packages = {}
    for architecture in ARCHITECTURES:
        # Reuse a matching thin package when migrating an existing installation.
        # Universal packages are handled by update() and need no rebuild.
        bundled = VENDOR / 'openssl'
        if supports_deployment_target(bundled) and all(
                architectures(bundled / 'lib' / name) == {architecture}
                for name in ['libssl.3.dylib', 'libcrypto.3.dylib']):
            packages[architecture] = bundled
            continue
        build_root = root / architecture
        if build_root.exists():
            shutil.rmtree(build_root)
        build_root.mkdir()
        with tarfile.open(archive) as compressed:
            compressed.extractall(build_root, filter='data')
        source = build_root / tag
        package = build_root / 'installed'
        target = {'arm64': 'darwin64-arm64-cc', 'x86_64': 'darwin64-x86_64-cc'}[architecture]
        env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=DEPLOYMENT_TARGET)
        # OpenSSL's generated linker commands do not quote an install prefix
        # with spaces. Install temporarily, then stage the matching package.
        with tempfile.TemporaryDirectory(prefix='torravia-openssl-', dir='/tmp') as temporary:
            prefix = pathlib.Path(temporary) / 'installed'
            run('perl', 'Configure', target, 'shared', 'no-tests',
                '--prefix=' + str(prefix), '--libdir=lib',
                '-mmacosx-version-min=' + DEPLOYMENT_TARGET, cwd=source, env=env)
            run('make', '-j' + str(min(os.cpu_count() or 2, 8)), cwd=source, env=env)
            run('make', 'install_sw', cwd=source, env=env)
            shutil.copytree(prefix, package)
        shutil.copy2(source / 'LICENSE.txt', package / 'LICENSE.txt')
        packages[architecture] = package
    merge_openssl_headers(packages, installed / 'include')
    (installed / 'lib').mkdir()
    for name in ['libssl.3.dylib', 'libcrypto.3.dylib']:
        # Normalize each slice before merging: the two builds have different
        # temporary install IDs and dependency paths.
        slices = []
        for architecture, package in packages.items():
            copied = root / (architecture + '-' + name)
            shutil.copy2(package / 'lib' / name, copied)
            normalize_dylib(copied, name)
            slices.append(str(copied))
        output = installed / 'lib' / name
        run('lipo', '-create', *slices, '-output', str(output))
        run('codesign', '--force', '--sign', '-', '--timestamp=none', str(output))
        if not is_universal(output):
            raise RuntimeError('OpenSSL is missing a required architecture')
    shutil.copy2(packages['arm64'] / 'LICENSE.txt', installed / 'LICENSE.txt')
    if not supports_deployment_target(installed):
        raise RuntimeError('Rebuilt OpenSSL does not support macOS ' + DEPLOYMENT_TARGET)
    write_json(installed / 'manifest.json', {'version': ssl_version, 'upstream_tag': tag,
               'source_sha256': asset['digest'], 'deployment_target': DEPLOYMENT_TARGET,
               'architectures': list(ARCHITECTURES)})
    return installed


def merge_openssl_headers(packages, destination):
    arm = packages['arm64'] / 'include'
    intel = packages['x86_64'] / 'include'
    arm_files = {p.relative_to(arm) for p in arm.rglob('*') if p.is_file()}
    intel_files = {p.relative_to(intel) for p in intel.rglob('*') if p.is_file()}
    if arm_files != intel_files:
        raise RuntimeError('OpenSSL architectures have different public header sets')
    shutil.copytree(arm, destination)
    for relative in sorted(arm_files):
        if (arm / relative).read_bytes() == (intel / relative).read_bytes():
            continue
        # Generated configuration is architecture-specific; all other public
        # declarations must match to safely use one universal dependency.
        if relative != pathlib.Path('openssl/configuration.h'):
            raise RuntimeError('Unexpected architecture-specific OpenSSL header: ' + str(relative))
        for architecture, package in packages.items():
            shutil.copy2(package / 'include' / relative,
                         destination / relative.with_name('configuration-' + architecture + '.h'))
        (destination / relative).write_text(
            '/* Generated by Torravia: matching configuration for each universal slice. */\n'
            '#if defined(__arm64__) || defined(__aarch64__)\n'
            '# include "configuration-arm64.h"\n'
            '#elif defined(__x86_64__)\n'
            '# include "configuration-x86_64.h"\n'
            '#else\n# error Unsupported OpenSSL architecture\n#endif\n')


def normalize_dylib(path, name):
    path.chmod(path.stat().st_mode | 0o200)
    # A copied package may be unsigned or signed. Remove any existing signature
    # before editing load commands; universal outputs are signed after merging.
    subprocess.run(['codesign', '--remove-signature', str(path)], stderr=subprocess.DEVNULL)
    run('install_name_tool', '-id', '@rpath/' + name, str(path))
    for line in subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines():
        dependency = line.strip().split(' (compatibility version', 1)[0]
        dependency_name = pathlib.Path(dependency).name
        if dependency_name in ['libssl.3.dylib', 'libcrypto.3.dylib'] and dependency != '@rpath/' + dependency_name:
            run('install_name_tool', '-change', dependency, '@rpath/' + dependency_name, str(path))


def update(release, wanted):
    brew = shutil.which('brew')
    if not brew:
        raise RuntimeError('Homebrew is needed to vendor the current native package')
    prefix = pathlib.Path(subprocess.check_output([brew, '--prefix'], text=True).strip())
    boost = (prefix / 'opt/boost').resolve()
    if not (boost / 'include/boost/version.hpp').exists():
        raise RuntimeError('Install Homebrew Boost to build the latest stable libtorrent')
    if not shutil.which('cmake'):
        raise RuntimeError('Install CMake to build the latest stable libtorrent')
    # Retain the bundled OpenSSL ABI and minimum OS. A Homebrew bottle may
    # target a newer OS than the application, even on a compatible build host.
    ssl_candidates = [VENDOR / 'openssl'] + sorted(WORK.glob('previous-*/openssl'), reverse=True)
    ssl = None
    for candidate in ssl_candidates:
        if supports_deployment_target(candidate) and all(is_universal(candidate / 'lib' / name)
                for name in ['libssl.3.dylib', 'libcrypto.3.dylib']):
            ssl = candidate
            break
    if ssl is None:
        ssl = rebuild_openssl()
    release_version = '.'.join(map(str, wanted))
    asset = next((a for a in release['assets'] if a['name'] == 'libtorrent-rasterbar-' + release_version + '.tar.gz'), None)
    if not asset or not re.fullmatch(r'sha256:[0-9a-f]{64}', asset.get('digest') or ''):
        raise RuntimeError('The stable source archive has no upstream SHA-256 digest')
    source_root = WORK / 'source'
    source_root.mkdir(exist_ok=True)
    archive = source_root / asset['name']
    if not archive.exists() or 'sha256:' + digest(archive) != asset['digest']:
        with urllib.request.urlopen(asset['browser_download_url'], timeout=60) as response:
            archive.write_bytes(response.read())
    if 'sha256:' + digest(archive) != asset['digest']:
        raise RuntimeError('Upstream source archive checksum mismatch')
    source = source_root / ('libtorrent-rasterbar-' + release_version)
    if source.exists():
        shutil.rmtree(source)
    with tarfile.open(archive) as compressed:
        # filter='data' rejects archive entries escaping the extraction root.
        compressed.extractall(source_root, filter='data')
    if version(source / 'include/libtorrent/version.hpp') != wanted:
        raise RuntimeError('Upstream source headers disagree with the release tag')
    with tempfile.TemporaryDirectory(prefix='staging-', dir=WORK) as temporary:
        staging = pathlib.Path(temporary)
        build = staging / 'build'
        installed = staging / 'installed'
        run('cmake', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + DEPLOYMENT_TARGET,
            '-DCMAKE_OSX_ARCHITECTURES=' + ';'.join(ARCHITECTURES),
            '-DCMAKE_INSTALL_PREFIX=' + str(installed), '-DBUILD_SHARED_LIBS=ON',
            '-Ddeprecated-functions=ON', '-Dbuild_tests=OFF', '-Dbuild_examples=OFF',
            '-Dbuild_tools=OFF', '-Dpython-bindings=OFF', '-Dwebtorrent=OFF',
            '-DBoost_DIR=' + str(next((boost / 'lib/cmake').glob('Boost-*'))),
            '-DOPENSSL_INCLUDE_DIR=' + str(ssl / 'include'),
            '-DOPENSSL_SSL_LIBRARY=' + str(ssl / 'lib/libssl.3.dylib'),
            '-DOPENSSL_CRYPTO_LIBRARY=' + str(ssl / 'lib/libcrypto.3.dylib'))
        run('cmake', '--build', str(build), '--parallel', str(min(os.cpu_count() or 2, 8)))
        run('cmake', '--install', str(build))
        for name, package_root in [('libtorrent', installed), ('openssl', ssl)]:
            target = staging / name
            shutil.copytree(package_root / 'include', target / 'include')
            (target / 'lib').mkdir()
            license_root = source if name == 'libtorrent' else package_root
            license_path = next((license_root / f for f in ['LICENSE', 'LICENSE.txt'] if (license_root / f).exists()), None)
            if license_path:
                shutil.copy2(license_path, target / license_path.name)
            if name == 'openssl' and (package_root / 'manifest.json').exists():
                shutil.copy2(package_root / 'manifest.json', target / 'manifest.json')
        # Use a version-independent filename and install ID so future patches
        # never leave Xcode or the helper linking a hard-coded old version.
        staged_library = staging / 'libtorrent/lib/libtorrent-rasterbar.dylib'
        library = installed / 'lib' / ('libtorrent-rasterbar.' + release_version + '.dylib')
        shutil.copy2(library, staged_library)
        normalize_dylib(staged_library, 'libtorrent-rasterbar.dylib')
        for name in ['libssl.3.dylib', 'libcrypto.3.dylib']:
            copied = staging / 'openssl/lib' / name
            shutil.copy2(ssl / 'lib' / name, copied)
            normalize_dylib(copied, name)
            run('codesign', '--force', '--sign', '-', '--timestamp=none', str(copied))
        run('codesign', '--force', '--sign', '-', '--timestamp=none', str(staged_library))
        targets = re.findall(r'minos\s+([\d.]+)', subprocess.check_output(['vtool', '-show-build', str(staged_library)], text=True))
        if not is_universal(staged_library) or len(targets) != len(ARCHITECTURES) or any(target != DEPLOYMENT_TARGET for target in targets):
            raise RuntimeError('Built library has the wrong minimum macOS version')
        if library_version(staged_library) != release_version + '.0':
            raise RuntimeError('Built library and upstream version disagree')
        env = dict(os.environ, LIBTORRENT_INCLUDE=str(staging / 'libtorrent/include'),
                   OPENSSL_INCLUDE=str(staging / 'openssl/include'), BOOST_INCLUDE=str(boost / 'include'),
                   BOOST_VENDOR_DIR=str(staging / 'boost'), MACOSX_DEPLOYMENT_TARGET=DEPLOYMENT_TARGET)
        run('bash', str(ROOT / 'scripts/vendor_boost_headers.sh'), env=env)
        with urllib.request.urlopen('https://www.boost.org/LICENSE_1_0.txt', timeout=30) as response:
            (staging / 'boost/LICENSE_1_0.txt').write_bytes(response.read())
        manifest = {'version': '.'.join(map(str, wanted)), 'upstream_tag': release['tag_name'],
                    'release_url': release['html_url'], 'published_at': release['published_at'],
                    'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'source': 'verified upstream source archive', 'source_sha256': asset['digest'],
                    'abi_version': 2, 'deployment_target': DEPLOYMENT_TARGET,
                    'architectures': list(ARCHITECTURES),
                    'dylib_sha256': digest(staged_library), 'boost_package': boost.name,
                    'boost_manifest_sha256': digest(staging / 'boost/manifest.txt'),
                    'boost_version_header_sha256': digest(staging / 'boost/include/boost/version.hpp'),
                    'openssl_dylib_sha256': {name: digest(staging / 'openssl/lib' / name)
                        for name in ['libssl.3.dylib', 'libcrypto.3.dylib']}}
        write_json(staging / 'libtorrent/manifest.json', manifest)
        backup = WORK / ('previous-' + str(time.time_ns()))
        backup.mkdir()
        moved, committed = [], []
        try:
            for name in ['libtorrent', 'openssl', 'boost']:
                target = VENDOR / name
                if target.exists():
                    target.rename(backup / name)
                    moved.append(name)
                (staging / name).rename(target)
                committed.append(name)
        except BaseException:
            for name in reversed(committed):
                shutil.rmtree(VENDOR / name)
            for name in moved:
                (backup / name).rename(VENDOR / name)
            raise
        print('Vendored libtorrent ' + manifest['version'] + '; previous dependencies: ' + str(backup))


def main():
    ensure_supported_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    with (WORK / 'update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        release, wanted = latest(args.refresh)
        current = installed_is_current(wanted)
        if args.check:
            print(json.dumps({'latest_stable': release['tag_name'], 'vendor_is_current': current}))
            return 0 if current else 1
        if not current:
            update(release, wanted)
        print('libtorrent ' + '.'.join(map(str, wanted)) + ' matches the latest stable upstream release.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('libtorrent update failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
