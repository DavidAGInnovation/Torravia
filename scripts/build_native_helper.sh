#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "${ROOT_DIR}/scripts/update_libtorrent.py"
APP_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
MACOS_DIR="${APP_DIR}/MacOS"
FRAMEWORKS_DIR="${APP_DIR}/Frameworks"
HELPER_SOURCE="${ROOT_DIR}/Sources/NativeTorrentHelper/TorrentNativeHelper.mm"
HELPER_OUTPUT="${MACOS_DIR}/TorrentNativeHelper"

LIBTORRENT_INCLUDE="${ROOT_DIR}/Vendor/libtorrent/include"
LIBTORRENT_DYLIB="${ROOT_DIR}/Vendor/libtorrent/lib/libtorrent-rasterbar.dylib"
OPENSSL_INCLUDE="${ROOT_DIR}/Vendor/openssl/include"
LIBSSL_DYLIB="${ROOT_DIR}/Vendor/openssl/lib/libssl.3.dylib"
LIBCRYPTO_DYLIB="${ROOT_DIR}/Vendor/openssl/lib/libcrypto.3.dylib"
BOOST_VENDOR_DIR="${ROOT_DIR}/Vendor/boost"
BOOST_INCLUDE="${BOOST_VENDOR_DIR}/include"
if [[ ! -d "${BOOST_INCLUDE}/boost" ]]; then
  BOOST_INCLUDE="/opt/homebrew/opt/boost/include"
fi
if [[ ! -d "${BOOST_INCLUDE}/boost" ]]; then
  BOOST_INCLUDE="/usr/local/opt/boost/include"
fi

if [[ ! -f "${HELPER_SOURCE}" ]]; then
  echo "Missing native helper source: ${HELPER_SOURCE}" >&2
  exit 1
fi

if [[ ! -d "${LIBTORRENT_INCLUDE}" || ! -f "${LIBTORRENT_DYLIB}" || ! -f "${LIBSSL_DYLIB}" || ! -f "${LIBCRYPTO_DYLIB}" ]]; then
  echo "Missing vendored native helper dependencies under Vendor/." >&2
  exit 1
fi

if [[ ! -d "${BOOST_INCLUDE}/boost" ]]; then
  echo "Missing Boost headers. Expected vendored headers under ${BOOST_VENDOR_DIR}/include or Homebrew boost under /opt/homebrew/opt/boost/include or /usr/local/opt/boost/include." >&2
  echo "Run scripts/vendor_boost_headers.sh on a machine with Homebrew boost installed to refresh the vendored subset." >&2
  exit 1
fi

mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}"
# Remove the previous runtime filenames after a dependency update.
/bin/rm -f "${FRAMEWORKS_DIR}"/libtorrent-rasterbar.[0-9]*.dylib

remove_signature_if_present() {
  local file="$1"
  /usr/bin/codesign --remove-signature "${file}" >/dev/null 2>&1 || true
}

copy_dylib() {
  local src="$1"
  local dest_name="${2:-$(basename "${src}")}"
  local dest="${FRAMEWORKS_DIR}/${dest_name}"
  cp -f "${src}" "${dest}"
  chmod u+w "${dest}"
  remove_signature_if_present "${dest}"
}

LIBTORRENT_RUNTIME_NAME="libtorrent-rasterbar.dylib"

copy_dylib "${LIBTORRENT_DYLIB}" "${LIBTORRENT_RUNTIME_NAME}"
copy_dylib "${LIBSSL_DYLIB}"
copy_dylib "${LIBCRYPTO_DYLIB}"

LIBTORRENT_BASENAME="${LIBTORRENT_RUNTIME_NAME}"
LIBSSL_BASENAME="$(basename "${LIBSSL_DYLIB}")"
LIBCRYPTO_BASENAME="$(basename "${LIBCRYPTO_DYLIB}")"

/usr/bin/xcrun clang++ \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:?Missing macOS deployment target}" \
  -std=c++20 \
  -fobjc-arc \
  -ObjC++ \
  -DTORRENT_LINKING_SHARED \
  -DTORRENT_ABI_VERSION=2 \
  -DTORRENT_USE_OPENSSL \
  -DTORRENT_USE_LIBCRYPTO \
  -DTORRENT_SSL_PEERS \
  -DBOOST_ASIO_ENABLE_CANCELIO \
  -DBOOST_ASIO_NO_DEPRECATED \
  -DBOOST_SYSTEM_USE_UTF8 \
  -I"${LIBTORRENT_INCLUDE}" \
  -I"${OPENSSL_INCLUDE}" \
  -I"${BOOST_INCLUDE}" \
  "${HELPER_SOURCE}" \
  "${LIBTORRENT_DYLIB}" \
  -lsqlite3 \
  -framework Foundation \
  -framework DiskArbitration \
  -framework IOKit \
  -framework SystemConfiguration \
  -Wl,-rpath,@executable_path/../Frameworks \
  -o "${HELPER_OUTPUT}"

chmod u+w "${HELPER_OUTPUT}"
remove_signature_if_present "${HELPER_OUTPUT}"

/usr/bin/install_name_tool -id "@rpath/${LIBTORRENT_BASENAME}" "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}"
/usr/bin/install_name_tool -id "@rpath/${LIBSSL_BASENAME}" "${FRAMEWORKS_DIR}/${LIBSSL_BASENAME}"
/usr/bin/install_name_tool -id "@rpath/${LIBCRYPTO_BASENAME}" "${FRAMEWORKS_DIR}/${LIBCRYPTO_BASENAME}"

rewrite_dependency_to_rpath() {
  local binary="$1"
  local dependency_name="$2"
  local dependency
  while IFS= read -r dependency; do
    if [[ "$(basename "${dependency}")" == "${dependency_name}" && "${dependency}" != "@rpath/${dependency_name}" ]]; then
      /usr/bin/install_name_tool -change "${dependency}" "@rpath/${dependency_name}" "${binary}"
    fi
  done < <(/usr/bin/otool -L "${binary}" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
}

# Homebrew embeds versioned Cellar paths in its dylibs. Rewrite dependencies
# by basename so the app remains self-contained across Homebrew versions.
rewrite_dependency_to_rpath "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}" "${LIBSSL_BASENAME}"
rewrite_dependency_to_rpath "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}" "${LIBCRYPTO_BASENAME}"
rewrite_dependency_to_rpath "${FRAMEWORKS_DIR}/${LIBSSL_BASENAME}" "${LIBCRYPTO_BASENAME}"
rewrite_dependency_to_rpath "${HELPER_OUTPUT}" "${LIBTORRENT_BASENAME}"
rewrite_dependency_to_rpath "${HELPER_OUTPUT}" "${LIBSSL_BASENAME}"
rewrite_dependency_to_rpath "${HELPER_OUTPUT}" "${LIBCRYPTO_BASENAME}"

verify_no_package_manager_dependencies() {
  local binary
  local dependency
  for binary in "$@"; do
    while IFS= read -r dependency; do
      case "${dependency}" in
        /opt/homebrew/*|/usr/local/Cellar/*)
          echo "External package-manager dependency remains in ${binary}: ${dependency}" >&2
          exit 1
          ;;
      esac
    done < <(/usr/bin/otool -L "${binary}" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
  done
}

verify_no_package_manager_dependencies \
  "${HELPER_OUTPUT}" \
  "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}" \
  "${FRAMEWORKS_DIR}/${LIBSSL_BASENAME}" \
  "${FRAMEWORKS_DIR}/${LIBCRYPTO_BASENAME}"

for binary in "${HELPER_OUTPUT}" "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}" \
  "${FRAMEWORKS_DIR}/${LIBSSL_BASENAME}" "${FRAMEWORKS_DIR}/${LIBCRYPTO_BASENAME}"; do
  for architecture in arm64 x86_64; do
    /usr/bin/lipo "${binary}" -verify_arch "${architecture}"
  done
done

sign_file() {
  local file="$1"
  local identity="-"
  if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  fi
  # Always ad-hoc sign nested artifacts. Without a signature, macOS can kill
  # the helper even when the surrounding app is intentionally unsigned.
  /usr/bin/codesign --force --sign "${identity}" --timestamp=none "${file}"
}

sign_file "${FRAMEWORKS_DIR}/${LIBCRYPTO_BASENAME}"
sign_file "${FRAMEWORKS_DIR}/${LIBSSL_BASENAME}"
sign_file "${FRAMEWORKS_DIR}/${LIBTORRENT_BASENAME}"
sign_file "${HELPER_OUTPUT}"

"${ROOT_DIR}/scripts/bundle_licenses.sh"
