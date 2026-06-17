#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.codex/hooks/permission-popup"
CONFIG_FILE="$HOME/.codex/config.toml"

echo "=== Codex Permission Popup Installer ==="
echo ""

echo "Building..."
cd "$SCRIPT_DIR"
make build

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/bin"
cp bin/permission-popup "$INSTALL_DIR/bin/"
cp codex-permission-hook.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/codex-permission-hook.sh"

echo "Configuring Codex hooks..."

HOOK_COMMAND="$INSTALL_DIR/codex-permission-hook.sh"

python3 - "$CONFIG_FILE" "$HOOK_COMMAND" <<'PY'
import os
import re
import sys

config_path, hook_command = sys.argv[1:]

os.makedirs(os.path.dirname(config_path), exist_ok=True)

if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        text = f.read()
else:
    text = ""


def ensure_hooks_enabled(contents: str) -> str:
    contents = re.sub(
        r"(?m)^\s*codex_hooks\s*=\s*(?:true|false)\s*$\n?",
        "",
        contents,
    )

    if re.search(r"(?m)^\s*hooks\s*=\s*true\s*$", contents):
        return contents

    if re.search(r"(?m)^\s*hooks\s*=\s*false\s*$", contents):
        return re.sub(
            r"(?m)^(\s*hooks\s*=\s*)false\s*$",
            r"\1true",
            contents,
            count=1,
        )

    features_match = re.search(r"(?m)^\[features\]\s*$", contents)
    if features_match:
        insert_at = features_match.end()
        return contents[:insert_at] + "\nhooks = true" + contents[insert_at:]

    prefix = "" if contents == "" or contents.endswith("\n") else "\n"
    return contents + prefix + "\n[features]\nhooks = true\n"


text = ensure_hooks_enabled(text)

if hook_command not in text:
    escaped_command = hook_command.replace("\\", "\\\\").replace('"', '\\"')
    block = f"""
[[hooks.PermissionRequest]]
matcher = ""

[[hooks.PermissionRequest.hooks]]
type = "command"
command = "{escaped_command}"
timeout = 600
statusMessage = "Waiting for permission popup"
"""
    prefix = "" if text == "" or text.endswith("\n") else "\n"
    text = text + prefix + block
    hook_added = True
else:
    hook_added = False

with open(config_path, "w", encoding="utf-8") as f:
    f.write(text)

print("Codex hooks enabled in config.toml")
print("Hook added to config.toml" if hook_added else "Hook already configured in config.toml")
PY

echo ""
echo "=== Installation complete ==="
echo ""
echo "The permission popup will now appear when Codex asks for approval."
echo ""
echo "Options in the popup:"
echo "  Allow        - Allow this one action"
echo "  Always Allow - Allow and add to Codex's allow list"
echo "  Deny         - Block this action"
echo ""
echo "Restart any running Codex sessions for the hook to take effect."
