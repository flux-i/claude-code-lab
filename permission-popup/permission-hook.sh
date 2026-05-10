#!/bin/bash
# Claude Code PermissionRequest hook handler
# Reads JSON from stdin and launches the native macOS popup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POPUP_BIN="$SCRIPT_DIR/bin/permission-popup"
export PERMISSION_POPUP_CLIENT=claude

# If binary not found, fall back to normal Claude Code prompt
if [ ! -x "$POPUP_BIN" ]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
    exit 0
fi

# Pipe stdin (hook JSON) directly to the popup binary
exec "$POPUP_BIN"
