# Torravia

Torravia is a native macOS torrent client with integrated Academic Torrents
search. Browse research datasets, open torrent files and magnet links, download
with libtorrent, and seed files you already have.

Requires macOS 14 or newer. The native engine supports Apple silicon and Intel.
Windows support is not available yet.

## Build and run

Clone the public source:

```sh
git clone https://github.com/Torravia/Torravia.git
cd Torravia
```

Install Xcode 26 or newer (Swift 6.2+), select it with `xcode-select`, and install
Python 3.12+ (`brew install python`). Open `Torravia.xcodeproj`, choose the
**Torravia** scheme, and run. Or use:

```sh
./build.sh
```

The build installs and launches `/Applications/Torravia.app`. Quit the app before
running tests. Local builds use ad-hoc signing; no Apple developer account or
private package is needed. For signed distribution, supply your own development
team and signing identity in Xcode. Do not distribute a development-signed build.

Matching universal libtorrent/OpenSSL libraries and Boost headers are bundled.
The build checks the latest stable libtorrent release; network access is required
for this check. If dependencies need updating, install CMake and Boost
(`brew install cmake boost`) and follow `scripts/update_libtorrent.py` diagnostics.

## Validate

```sh
python3 scripts/update_libtorrent.py --refresh
xcodebuild test -project Torravia.xcodeproj -scheme Torravia \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData
python3 Tests/NativeTorrentHelper/UniversalCompatibilityTests.py
```

Native compatibility checks verify the bundle signature, universal slices,
local transfers against piece hashes, tracker behavior, and resume state. They
run on the host's native architecture by default. Test on physical Apple silicon
and Intel Macs for both architectures; Rosetta is optional and requires an
explicit `--all-architectures` argument.

## Features

- Academic Torrents dataset search, source links, and availability checks.
- Torrent files, magnets, download queues, pause/resume, and bandwidth controls.
- Torrent creation, existing-file seeding, and configurable seeding limits.
- RSS rules and authenticated local browser control, with optional HTTPS.

Search contacts Academic Torrents. Torrent transfer can contact trackers, peers,
and DHT nodes. Opening a torrent or magnet uses its supplied metadata and trackers.
Browser control is disabled until enabled in Settings; Torravia must remain running.

## Project layout

`Sources/Torravia` contains the app and Academic Torrents provider.
`Packages/TorraviaSearch` contains shared provider contracts, result models, and
parsing utilities. `Sources/NativeTorrentHelper` contains the libtorrent bridge.
The public project has no private package dependency. Optional private extensions
can live in a separately versioned `Private/` checkout, ignored by this repository;
public builds and tests do not require it.

## License and contributions

Public Torravia source is MIT licensed. See [LICENSE](LICENSE),
[third-party notices](THIRD_PARTY_NOTICES.md), [contributing](CONTRIBUTING.md), and
[security reporting](SECURITY.md). Third-party code retains its own license.
