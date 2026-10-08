#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT_DIR/scripts/update_libtorrent.py" --refresh
STATE_DIR="$ROOT_DIR/.build/installed-product"
CONFIGURATION_FILE="$STATE_DIR/configuration"
APP_PATH="/Applications/Torravia.app"
BUILD_CONFIGURATION="${CONFIGURATION:?Xcode must supply CONFIGURATION}:${PROJECT_NAME:-Torravia}"

mkdir -p "$STATE_DIR"

# Retire the former name while retaining a recoverable bundle. Both names use
# the same sandbox identity and queue, so only the new app should be installed.
LEGACY_APP="/Applications/TorrentScout.app"
if [[ -d "$LEGACY_APP" ]]; then
  pkill -x TorrentScout >/dev/null 2>&1 || true
  for attempt in {1..50}; do
    if ! pgrep -x TorrentScout >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x TorrentScout >/dev/null; then
    echo "TorrentScout is still running; quit it before rebuilding Torravia." >&2
    exit 1
  fi
  LEGACY_BACKUP="$STATE_DIR/legacy-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$LEGACY_BACKUP"
  mv "$LEGACY_APP" "$LEGACY_BACKUP/TorrentScout.app"
fi

PREVIOUS_CONFIGURATION=""
if [[ -f "$CONFIGURATION_FILE" ]]; then
  PREVIOUS_CONFIGURATION="$(cat "$CONFIGURATION_FILE")"
fi

# Separate checkouts have separate cache markers. Inspect the actual installed
# identity too, so switching public/private projects cannot reuse the other app.
INSTALLED_BUNDLE_IDENTIFIER=""
if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
  INSTALLED_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
fi
EXPECTED_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-}"
IDENTITY_CHANGED=false
if [[ -n "$EXPECTED_BUNDLE_IDENTIFIER" && "$INSTALLED_BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  IDENTITY_CHANGED=true
fi

# Debug and Release share the installed bundle but have different intermediate
# products. Remove the prior bundle before Xcode plans its build, so it cannot
# mistake a newer binary from the other configuration for its own cached output.
if [[ -d "$APP_PATH" && ( "$PREVIOUS_CONFIGURATION" != "$BUILD_CONFIGURATION" || "$IDENTITY_CHANGED" == true ) ]]; then
  pkill -x Torravia >/dev/null 2>&1 || true
  PREVIOUS_APP="$STATE_DIR/previous/Torravia.app"
  mkdir -p "$(dirname "$PREVIOUS_APP")"
  if [[ -e "$PREVIOUS_APP" ]]; then
    /usr/bin/trash "$PREVIOUS_APP"
  fi
  mv "$APP_PATH" "$PREVIOUS_APP"
fi
printf '%s\n' "$BUILD_CONFIGURATION" > "$CONFIGURATION_FILE"
