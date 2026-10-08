#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/scripts/update_libtorrent.py" --refresh
PROJECT_PATH="${PROJECT_PATH:-$SCRIPT_DIR/Torravia.xcodeproj}"
SCHEME="${SCHEME:-Torravia}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$SCRIPT_DIR/.build/DerivedData}"
INSTALL_DIR="/Applications"

COMMON_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

BUILD_SETTINGS="$(xcodebuild "${COMMON_ARGS[@]}" -showBuildSettings)"
TARGET_BUILD_DIR="$(awk -F ' = ' '/TARGET_BUILD_DIR = / { print $2; exit }' <<<"$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '/FULL_PRODUCT_NAME = / { print $2; exit }' <<<"$BUILD_SETTINGS")"
APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
INSTALL_APP_PATH="$INSTALL_DIR/$FULL_PRODUCT_NAME"

# Stop existing copies before replacing the bundle so opening the finished
# build cannot bring an older running process back to the foreground.
APP_EXECUTABLE="$(awk -F ' = ' '/EXECUTABLE_NAME = / { print $2; exit }' <<<"$BUILD_SETTINGS")"
if [ -n "$APP_EXECUTABLE" ]; then
  pkill -x "$APP_EXECUTABLE" >/dev/null 2>&1 || true
fi

xcodebuild build "${COMMON_ARGS[@]}"

if [ ! -d "$APP_PATH" ]; then
  echo "Built app not found at: $APP_PATH" >&2
  exit 1
fi

if [ "$APP_PATH" != "$INSTALL_APP_PATH" ]; then
  mkdir -p "$INSTALL_DIR"
  if [ -e "$INSTALL_APP_PATH" ]; then
    if [ ! -x /usr/bin/trash ]; then
      echo "Cannot replace existing app: /usr/bin/trash is unavailable." >&2
      exit 1
    fi
    /usr/bin/trash "$INSTALL_APP_PATH"
  fi
  ditto "$APP_PATH" "$INSTALL_APP_PATH"
fi

if [ ! -d "$INSTALL_APP_PATH" ]; then
  echo "Installed app not found at: $INSTALL_APP_PATH" >&2
  exit 1
fi

echo "Installed app: $INSTALL_APP_PATH"
open "$INSTALL_APP_PATH"
