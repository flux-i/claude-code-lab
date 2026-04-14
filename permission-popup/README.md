# permission-popup

A native macOS popup that replaces Claude Code's in-terminal permission prompts. When Claude Code needs permission to run a tool (Bash, Edit, Write, etc.), a window appears over all apps with **Allow**, **Always Allow**, or **Deny**.

It hooks into Claude Code's `PermissionRequest` event, so nothing in Claude Code itself changes — you just get a real OS dialog instead of a TUI prompt.

## Supported platforms

- **macOS only.** The popup is written in Swift against Cocoa/AppKit.
- Tested on Apple Silicon. Intel Macs should work but are untested.

## Prerequisites

- **macOS** with Xcode Command Line Tools installed (provides `swiftc`):
  ```sh
  xcode-select --install
  ```
- **Python 3** (used by `install.sh` to patch `~/.claude/settings.json`). Ships with macOS.
- **Claude Code** already installed and configured.

## Install

```sh
git clone https://github.com/flux-i/claude-code-lab.git
cd claude-code-lab/permission-popup
./install.sh
```

The installer will:
1. Build the Swift binary into `bin/permission-popup`.
2. Copy the binary and `permission-hook.sh` to `~/.claude/hooks/permission-popup/`.
3. Register a `PermissionRequest` hook in `~/.claude/settings.json` (skipped if already present).

Restart any running Claude Code sessions for the hook to take effect.

## Manual install

If you'd rather not run the installer, build and wire it up yourself:

```sh
make build
make install   # copies files, then prints the settings.json snippet to paste in
```

Then add the printed block to `~/.claude/settings.json` under `hooks.PermissionRequest`.

## Uninstall

```sh
make uninstall
```

Then remove the `PermissionRequest` entry from `~/.claude/settings.json`.

## Test

```sh
make test
```

Feeds a sample `PermissionRequest` event to the binary so you can see the popup without running Claude Code.

## Layout

```
permission-popup/
├── src/PermissionPopup.swift   # the Cocoa app
├── permission-hook.sh          # shim Claude Code invokes
├── install.sh                  # one-shot installer
└── Makefile                    # build / install / uninstall / test targets
```
