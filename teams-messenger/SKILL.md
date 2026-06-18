---
name: teams-messenger
description: Send or read Microsoft Teams chats by person name or email on macOS. Use whenever the user wants to send/DM someone on Teams (e.g. "send X to Alex", "message Sam on Teams saying I'm running late", "DM Jordan the build is green") or read a Teams conversation ("what did Alex say on Teams", "read my Teams chat with Sam"). Resolves a spoken name to an email via a bundled contacts map, then drives the Teams desktop app via UI automation (no API/browser).
---

# Teams Messenger

## Overview

Sends and reads Microsoft Teams chats on macOS by name or email, driving the Teams desktop app through the macOS Accessibility API and `msteams:` deep links. It uses UI automation because the org has disabled the Graph API, app registration, and Power Automate — there is no headless/API path. Everything is one compiled Swift binary: `scripts/teams` (no bash, no osascript).

## Build

The compiled binary is gitignored — build it once before first use:

```bash
swiftc -O -o scripts/teams scripts/teams.swift -framework AppKit -framework ApplicationServices
```

## When to use

Use when the user wants to **send** a Teams message ("send X to Alex", "message Sam …", "DM Jordan …") or **read** a Teams chat ("what did Alex say on Teams", "read my chat with Sam"). Recipients may be a first name, full name, or raw email.

## Sending

Run the binary (paths are relative to this skill's base directory). It **sends for real by default**.

```bash
# 1:1 chat:
scripts/teams send "<name-or-email>" "<message>"

# GROUP chat — several recipients in ONE chat (comma- or "and"-separated):
scripts/teams send "Alex, Sam, Jordan" "<message>"

# BROADCAST — same message as a SEPARATE 1:1 DM to each person:
scripts/teams send --each "Alex, Sam and Jordan" "<message>"

# IMAGE attachment:
scripts/teams send "<name-or-email>" "<message>" --attach ~/path/to/image.png

# DRY RUN — prepare but do NOT press Send (prefills/types only):
scripts/teams send --dry "<name-or-email>" "<message>"
```

**Choosing the mode:** several names with no flag → one **group chat**; with `--each` → **individual DMs** to each. Pick `--each` for most "tell everyone X" requests, and the no-flag group mode when they should all be in one conversation.

**Sending vs testing:** sends by default. Use `--dry` only when explicitly testing — and after a dry run, never report a message as actually sent (it was only prepared in the compose box).

## Reading

```bash
scripts/teams read                       # read the currently-open chat
scripts/teams read "<name-or-email>"     # open that chat, then read it
```

Reads the visible messages from the right-hand chat pane via the Accessibility API and prints them to stdout. It never writes chat content to disk.

## Name → email resolution

The binary resolves recipients via `scripts/teams_contacts.txt` (format `Name = email`, one per line). That file is **gitignored** — copy `scripts/teams_contacts.example.txt` to `scripts/teams_contacts.txt` and fill in real contacts.

- If the input contains `@`, it is treated as a raw email and used directly.
- Otherwise it is matched case-insensitively as a substring of contact names.
- An **ambiguous** match (a fragment matching two people) is refused with the candidate list — use a more specific name and re-run.
- An **unknown** name is refused and the known contacts are printed — never guess an email; ask the user or add the contact.

To add a contact, edit `scripts/teams_contacts.txt` (`First Last = first.lastinitial@company.com`), following your org's email pattern with any per-person exceptions.

Multiple recipients (names or emails) may be separated by commas or the word "and"; each is resolved independently, and any unresolved name aborts the whole send (nothing is sent) so no message goes to the wrong person.

## Behavior & limits

- **Not headless.** Any `msteams:` deep-link open makes Teams activate its *own* window (Electron pulls itself forward), so a send — or a `read` that navigates to a named chat — brings Teams to the front. The binary **restores focus** to the app you were using and returns you there. On macOS 26 this is non-trivial: Teams self-activates *asynchronously*, often just after the CLI would exit, and a background CLI cannot reorder apps via `NSRunningApplication.activate()`/`.hide()` or the Accessibility API (all ignored). So restore is done by a **detached helper** (`teams __refocus`, spawned automatically) that outlives the command, waits for Teams' late grab, and re-opens the previous app via LaunchServices (`/usr/bin/open`) — which works with no extra permission. The result is printed before this kicks off, so the command returns immediately while focus is fixed in the background. It only ever reclaims focus *from Teams* (won't fight you if you switch elsewhere).
- **Text injection:** when navigating, the message is injected via the deep-link `&message=` prefill (atomic, no per-keystroke failures); if the target chat is already open the prefill is ignored and it falls back to `⌘R` + typed keystrokes. **Send** is an Accessibility press on the Send button (falls back to Return).
- **Attachments:** images work (pasted via the pasteboard, which needs Teams briefly focused). Arbitrary files (PDF/zip) are **not yet supported**.
- Requires macOS **Accessibility permission** for the controlling terminal (System Settings → Privacy & Security → Accessibility), and the **Teams desktop app** installed and signed in.

## Troubleshooting

- **Keystrokes/clicks do nothing** → grant Accessibility permission to the controlling terminal, then retry.
- **Message didn't appear in the chat** → the compose box wasn't focused or the prefill was ignored; confirm the right chat opened.
- **Wrong person / chat didn't open** → the resolved email may not match a real user; verify it in `teams_contacts.txt`.
