#!/bin/bash
# Codex PermissionRequest hook handler
# Reads JSON from stdin and launches the native macOS popup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POPUP_BIN="$SCRIPT_DIR/bin/permission-popup"
export PERMISSION_POPUP_CLIENT=codex

# If binary not found, emit no decision so Codex falls back to its normal prompt.
if [ ! -x "$POPUP_BIN" ]; then
    exit 0
fi

# Pipe stdin (hook JSON) directly to the popup binary.
exec "$POPUP_BIN"
