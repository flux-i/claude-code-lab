#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claude/hooks/permission-popup"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== Claude Code Permission Popup Installer ==="
echo ""

# Build
echo "Building..."
cd "$SCRIPT_DIR"
make build

# Install binary and hook script
echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/bin"
cp bin/permission-popup "$INSTALL_DIR/bin/"
cp permission-hook.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/permission-hook.sh"

# Update settings.json
echo "Configuring Claude Code hooks..."

HOOK_COMMAND="$INSTALL_DIR/permission-hook.sh"

python3 -c "
import json, os, sys

settings_path = '$SETTINGS_FILE'

# Read existing settings
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

# Build the hook entry
hook_entry = {
    'matcher': '',
    'hooks': [
        {
            'type': 'command',
            'command': '$HOOK_COMMAND',
            'timeout': 600
        }
    ]
}

# Add/update PermissionRequest hooks
hooks = settings.get('hooks', {})
perm_hooks = hooks.get('PermissionRequest', [])

# Check if already installed
already_installed = any(
    any(h.get('command', '') == '$HOOK_COMMAND' for h in entry.get('hooks', []))
    for entry in perm_hooks
)

if not already_installed:
    perm_hooks.append(hook_entry)
    hooks['PermissionRequest'] = perm_hooks
    settings['hooks'] = hooks

    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    print('Hook added to settings.json')
else:
    print('Hook already configured in settings.json')
"

echo ""
echo "=== Installation complete ==="
echo ""
echo "The permission popup will now appear over all windows when"
echo "Claude Code needs permission to run a tool."
echo ""
echo "Options in the popup:"
echo "  Allow        - Allow this one action"
echo "  Always Allow - Allow and add to your permanent allowlist"
echo "  Deny         - Block this action"
echo ""
echo "To uninstall: make uninstall (and remove hook from settings.json)"
