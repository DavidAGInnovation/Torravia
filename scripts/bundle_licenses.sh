#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"
LICENSE_DIR="$RESOURCE_DIR/Licenses"
mkdir -p "$LICENSE_DIR"
cp "$ROOT_DIR/LICENSE" "$LICENSE_DIR/Torravia-MIT.txt"
cp "$ROOT_DIR/Vendor/libtorrent/LICENSE" "$LICENSE_DIR/libtorrent-BSD.txt"
cp "$ROOT_DIR/Vendor/boost/LICENSE_1_0.txt" "$LICENSE_DIR/Boost.txt"
cp "$ROOT_DIR/Vendor/openssl/LICENSE.txt" "$LICENSE_DIR/OpenSSL-Apache-2.0.txt"
cp "$ROOT_DIR/Sources/Torravia/Downloads/Web/Lucide-LICENSE.txt" "$LICENSE_DIR/Lucide-ISC.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCE_DIR/THIRD_PARTY_NOTICES.md"
if [[ -n "${ADDITIONAL_LICENSE_FILE:-}" ]]; then
  cp "$ADDITIONAL_LICENSE_FILE" "$LICENSE_DIR/AdditionalComponents.txt"
fi
