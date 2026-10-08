#!/usr/bin/env bash
set -euo pipefail
APP_BINARY="/Applications/Torravia.app/Contents/MacOS/Torravia"
if [[ ! -x "$APP_BINARY" ]]; then
  echo "Install Torravia in /Applications before starting headless mode." >&2
  exit 1
fi
exec "$APP_BINARY" --headless "$@"
