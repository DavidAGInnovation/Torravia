"""Regression checks for stable-release selection and dependency integrity."""
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('updater', pathlib.Path(__file__).resolve().parents[2] / 'scripts/update_libtorrent.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class DependencyUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.work_patch = patch.object(updater, 'WORK', self.root)
        self.work_patch.start()

    def tearDown(self):
        self.work_patch.stop()
        self.temporary.cleanup()

    def test_excludes_prereleases_and_development_versions(self):
        for release in [{'tag_name': 'v2.2.0-rc1', 'prerelease': True},
                        {'tag_name': 'master'}, {'tag_name': 'v2.2.0', 'draft': True}]:
            with self.subTest(release=release), patch.object(updater.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(release).encode())):
                with self.assertRaisesRegex(RuntimeError, 'stable semantic version'):
                    updater.latest(refresh=True)

    def test_explicit_refresh_does_not_hide_network_failure_with_cached_version(self):
        updater.write_json(self.root / 'upstream-release.json', {'tag_name': 'v2.1.1'})
        with patch.object(updater.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaisesRegex(OSError, 'offline'):
                updater.latest(refresh=True)

    def test_refresh_replaces_cached_old_release(self):
        updater.write_json(self.root / 'upstream-release.json', {'tag_name': 'v2.1.1'})
        release = {'tag_name': 'v2.1.2', 'prerelease': False, 'draft': False}
        with patch.object(updater.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(release).encode())):
            self.assertEqual(updater.latest(refresh=True)[1], (2, 1, 2))
        self.assertEqual(json.loads((self.root / 'upstream-release.json').read_text()), release)

    def test_authenticated_release_request_uses_token_header(self):
        release = {'tag_name': 'v2.1.2'}
        with patch.dict(updater.os.environ, {'GITHUB_TOKEN': 'test-token'}, clear=True), \
                patch.object(updater.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(release).encode())) as fetch:
            self.assertEqual(updater.latest(refresh=True)[1], (2, 1, 2))
            request = fetch.call_args.args[0]
            self.assertEqual(request.get_header('Authorization'), 'Bearer test-token')
            self.assertEqual(request.full_url, updater.API)

    def test_fallback_sends_authentication_over_stdin_not_command_arguments(self):
        release = {'tag_name': 'v2.1.2'}
        with patch.dict(updater.os.environ, {'GITHUB_TOKEN': 'test-token'}, clear=True), \
                patch.object(updater.urllib.request, 'urlopen', side_effect=updater.urllib.error.URLError('connection failed')), \
                patch.object(updater.subprocess, 'check_output', return_value=json.dumps(release)) as fallback:
            self.assertEqual(updater.latest(refresh=True)[1], (2, 1, 2))
            command = fallback.call_args.args[0]
            self.assertNotIn('test-token', ' '.join(command))
            self.assertIn('@-', command)
            self.assertIn('Authorization: Bearer test-token\n', fallback.call_args.kwargs['input'])
            self.assertEqual(command[-1], updater.API)

    def test_integrity_check_rejects_library_tampering_and_newer_os_requirement(self):
        vendor = self.root / 'Vendor'
        contents = {'libtorrent/include/libtorrent/version.hpp':
                    '#define LIBTORRENT_VERSION_MAJOR 2\n#define LIBTORRENT_VERSION_MINOR 1\n#define LIBTORRENT_VERSION_TINY 2\n',
                    'libtorrent/lib/libtorrent-rasterbar.dylib': 'library',
                    'boost/manifest.txt': 'boost/version.hpp',
                    'boost/include/boost/version.hpp': 'boost',
                    'openssl/lib/libssl.3.dylib': 'ssl', 'openssl/lib/libcrypto.3.dylib': 'crypto'}
        for name, value in contents.items():
            path = vendor / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        library = vendor / 'libtorrent/lib/libtorrent-rasterbar.dylib'
        manifest = {'version': '2.1.2', 'deployment_target': updater.DEPLOYMENT_TARGET,
                    'architectures': list(updater.ARCHITECTURES),
                    'dylib_sha256': updater.digest(library),
                    'boost_manifest_sha256': updater.digest(vendor / 'boost/manifest.txt'),
                    'boost_version_header_sha256': updater.digest(vendor / 'boost/include/boost/version.hpp'),
                    'openssl_dylib_sha256': {name: updater.digest(vendor / 'openssl/lib' / name)
                                             for name in ['libssl.3.dylib', 'libcrypto.3.dylib']}}
        path = vendor / 'libtorrent/manifest.json'
        updater.write_json(path, manifest)
        with patch.object(updater, 'VENDOR', vendor), patch.object(updater, 'architectures', return_value=set(updater.ARCHITECTURES)):
            self.assertTrue(updater.installed_is_current((2, 1, 2)))
            with patch.object(updater, 'architectures', return_value={'arm64'}):
                self.assertFalse(updater.installed_is_current((2, 1, 2)))
            manifest['deployment_target'] = '27.0'
            updater.write_json(path, manifest)
            self.assertFalse(updater.installed_is_current((2, 1, 2)))
            manifest['deployment_target'] = updater.DEPLOYMENT_TARGET
            updater.write_json(path, manifest)
            library.write_text('corrupted')
            self.assertFalse(updater.installed_is_current((2, 1, 2)))

    def test_missing_intel_slice_is_not_a_universal_package(self):
        with patch.object(updater, 'architectures', return_value={'arm64'}):
            self.assertFalse(updater.is_universal(self.root / 'library'))

    def test_openssl_configuration_uses_the_matching_architecture(self):
        packages = {architecture: self.root / architecture for architecture in updater.ARCHITECTURES}
        for architecture, package in packages.items():
            includes = package / 'include/openssl'
            includes.mkdir(parents=True)
            (includes / 'configuration.h').write_text('/* ' + architecture + ' */\n')
            (includes / 'ssl.h').write_text('/* Shared declarations */\n')
        destination = self.root / 'merged'
        updater.merge_openssl_headers(packages, destination)
        dispatch = (destination / 'openssl/configuration.h').read_text()
        for architecture in updater.ARCHITECTURES:
            self.assertIn('configuration-' + architecture + '.h', dispatch)
            self.assertEqual((destination / ('openssl/configuration-' + architecture + '.h')).read_text(),
                             (packages[architecture] / 'include/openssl/configuration.h').read_text())
        (packages['x86_64'] / 'include/openssl/ssl.h').write_text('/* Incompatible declarations */\n')
        with self.assertRaisesRegex(RuntimeError, 'Unexpected architecture-specific'):
            updater.merge_openssl_headers(packages, self.root / 'invalid')

    def test_openssl_compatibility_checks_every_architecture_and_library(self):
        package = self.root / 'openssl'
        (package / 'lib').mkdir(parents=True)
        for name in ['libssl.3.dylib', 'libcrypto.3.dylib']:
            (package / 'lib' / name).touch()
        target = 'minos ' + updater.DEPLOYMENT_TARGET
        with patch.object(updater.subprocess, 'check_output', side_effect=[target, target]):
            self.assertTrue(updater.supports_deployment_target(package))
        # A universal library is incompatible if even one slice is too new.
        for outputs in [[target + '\nminos 27.0', target], [target, 'minos 27.0'], [target, '']]:
            with self.subTest(outputs=outputs), patch.object(updater.subprocess, 'check_output', side_effect=outputs):
                self.assertFalse(updater.supports_deployment_target(package))

    def test_old_python_without_supported_interpreter_fails_before_extraction(self):
        with patch.object(updater.sys, 'version_info', (3, 9)), patch.object(updater.pathlib.Path, 'exists', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'Python 3.12 or newer'):
                updater.ensure_supported_python()


if __name__ == '__main__':
    unittest.main()
