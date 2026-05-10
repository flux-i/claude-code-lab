# permission-popup

A native macOS popup that replaces Claude Code and Codex in-terminal permission prompts. When either tool needs permission to run an action, a window appears over all apps with **Allow**, **Always Allow**, or **Deny**.

It hooks into each tool's `PermissionRequest` event, so the agent keeps using its normal approval protocol while you get a real OS dialog instead of a TUI prompt.

## Supported platforms

- **macOS only.** The popup is written in Swift against Cocoa/AppKit.
- Tested on Apple Silicon. Intel Macs should work but are untested.

## Prerequisites

- **macOS** with Xcode Command Line Tools installed (provides `swiftc`):
  ```sh
  xcode-select --install
  ```
- **Python 3** (used by the installers to patch local config files). Ships with macOS.
- **Claude Code** and/or **Codex** already installed and configured.

## Install for Claude Code

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

## Install for Codex

```sh
git clone https://github.com/flux-i/claude-code-lab.git
cd claude-code-lab/permission-popup
./install-codex.sh
```

The installer will:
1. Build the Swift binary into `bin/permission-popup`.
2. Copy the binary and `codex-permission-hook.sh` to `~/.codex/hooks/permission-popup/`.
3. Enable `features.hooks` and register a `PermissionRequest` hook in `~/.codex/config.toml` (skipped if already present).

Restart any running Codex sessions for the hook to take effect.

For Codex, **Always Allow** stores popup-specific allow patterns in `~/.codex/permission-popup-allow.json`. For Bash approvals it also appends a matching `prefix_rule(..., decision="allow")` to `~/.codex/rules/default.rules`, which is Codex's native allow-list path.

## Manual install

If you'd rather not run the installers, build and wire it up yourself:

```sh
make build
make install-claude   # copies files, then prints the Claude settings.json snippet
make install-codex    # copies files, then prints the Codex config.toml snippet
```

Then add the printed block to the relevant config file:

- Claude Code: `~/.claude/settings.json` under `hooks.PermissionRequest`
- Codex: `~/.codex/config.toml`

## Uninstall

```sh
make uninstall-claude
make uninstall-codex
```

Then remove the `PermissionRequest` entry from the relevant config file.

## Test

```sh
make test        # Claude-style sample payload
make test-codex  # Codex-style sample payload
```

Feeds a sample `PermissionRequest` event to the binary so you can see the popup without running Claude Code or Codex.

## Layout

```
permission-popup/
├── src/PermissionPopup.swift   # the Cocoa app
├── permission-hook.sh          # shim Claude Code invokes
├── codex-permission-hook.sh    # shim Codex invokes
├── install.sh                  # Claude Code installer
├── install-codex.sh            # Codex installer
└── Makefile                    # build / install / uninstall / test targets
```
