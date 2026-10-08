#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_SOURCE="${ROOT_DIR}/Sources/NativeTorrentHelper/TorrentNativeHelper.mm"
LIBTORRENT_INCLUDE="${LIBTORRENT_INCLUDE:-${ROOT_DIR}/Vendor/libtorrent/include}"
OPENSSL_INCLUDE="${OPENSSL_INCLUDE:-${ROOT_DIR}/Vendor/openssl/include}"
BOOST_INCLUDE="${BOOST_INCLUDE:-/opt/homebrew/opt/boost/include}"
if [[ ! -d "${BOOST_INCLUDE}/boost" ]]; then
  BOOST_INCLUDE="/usr/local/opt/boost/include"
fi

if [[ ! -f "${HELPER_SOURCE}" ]]; then
  echo "Missing helper source: ${HELPER_SOURCE}" >&2
  exit 1
fi

if [[ ! -d "${LIBTORRENT_INCLUDE}" ]]; then
  echo "Missing vendored libtorrent headers under ${LIBTORRENT_INCLUDE}" >&2
  exit 1
fi

if [[ ! -d "${BOOST_INCLUDE}/boost" ]]; then
  echo "Missing Homebrew Boost headers. Install boost before refreshing the vendored subset." >&2
  exit 1
fi

VENDOR_ROOT="${BOOST_VENDOR_DIR:-${ROOT_DIR}/Vendor/boost}"
VENDOR_INCLUDE="${VENDOR_ROOT}/include"
MANIFEST_PATH="${VENDOR_ROOT}/manifest.txt"
BOOST_PREFIX="$(cd "${BOOST_INCLUDE}/.." && pwd)"
LICENSE_SOURCE="${BOOST_PREFIX}/LICENSE_1_0.txt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

DEPS_FILE="${TMP_DIR}/native-helper.d"
RAW_MANIFEST="${TMP_DIR}/manifest.txt"

for architecture in arm64 x86_64; do
  /usr/bin/xcrun clang++ \
    -arch "${architecture}" \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
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
    -M "${HELPER_SOURCE}" >> "${DEPS_FILE}"
done

/usr/bin/tr '\\\n' '  ' < "${DEPS_FILE}" \
  | /usr/bin/tr ' ' '\n' \
  | /usr/bin/grep "^${BOOST_INCLUDE}/" \
  | /usr/bin/sed "s#^${BOOST_INCLUDE}/##" \
  | /usr/bin/sort -u > "${RAW_MANIFEST}"

if [[ ! -s "${RAW_MANIFEST}" ]]; then
  echo "Failed to resolve Boost header dependencies for the native helper." >&2
  exit 1
fi

/bin/rm -rf "${VENDOR_ROOT}"
/bin/mkdir -p "${VENDOR_INCLUDE}"

while IFS= read -r relative_path; do
  [[ -n "${relative_path}" ]] || continue
  /bin/mkdir -p "${VENDOR_INCLUDE}/$(dirname "${relative_path}")"
  /bin/cp -f "${BOOST_INCLUDE}/${relative_path}" "${VENDOR_INCLUDE}/${relative_path}"
done < "${RAW_MANIFEST}"

/bin/cp -f "${RAW_MANIFEST}" "${MANIFEST_PATH}"

if [[ -f "${LICENSE_SOURCE}" ]]; then
  /bin/cp -f "${LICENSE_SOURCE}" "${VENDOR_ROOT}/LICENSE_1_0.txt"
fi

HEADER_COUNT="$(/usr/bin/wc -l < "${MANIFEST_PATH}" | /usr/bin/tr -d ' ')"
VENDOR_SIZE="$(/usr/bin/du -sh "${VENDOR_INCLUDE}" | /usr/bin/awk '{print $1}')"

echo "Vendored ${HEADER_COUNT} Boost headers into ${VENDOR_INCLUDE} (${VENDOR_SIZE})."
