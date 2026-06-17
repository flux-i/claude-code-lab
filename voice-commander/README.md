# ClaudeVoice

A tiny macOS menu-bar app that turns your voice into Claude Code commands.

> **Hold Right ⌘ → speak → release.** Claude executes your instruction on your machine and **talks the answer back**, while a small space-black card streams the words in the top-right of your screen.

It's a hands-free front end for headless Claude Code (`claude -p`): on-device speech-to-text in, your spoken command runs with full tool access, and the reply is spoken aloud. Multi-turn — it remembers the conversation between commands.

---

## What it looks like

A compact card fades in under the menu bar (top-right):

- **Listening** — a blue breathing orb + your live transcript
- **Thinking** — a violet orb while Claude works
- **Speaking** — a green orb; Claude's reply is read aloud and the text streams past in a rolling ~10-word window, then the card fades out

No "done" screen, no wall of text — just the words currently being spoken.

## How it works

```
Hold Right ⌘ ──▶ ClaudeVoice.app ──▶ ~/.claude/voice/voice-agent.sh ──▶ claude -p
   (hotkey)      (Speech → text)         (session logic)              (executes)
       ▲                                                                   │
       └──────────────  spoken reply + streamed text  ◀────────────────────┘
```

- **The app** (`Sources/main.swift`) owns the global hotkey, on-device speech recognition (Apple `Speech`), the HUD, and text-to-speech.
- **The shell agent** (`~/.claude/voice/voice-agent.sh`) owns everything Claude-related: which session to use, the system prompt, and parsing the reply. Keeping this in shell means the rules can change **without rebuilding the app**.

### Conversation continuity

Each command **continues the previous Claude session** if it was used **< 1 hour ago AND its context is < 300k tokens**. Otherwise it **starts a fresh session**. State lives in `~/.claude/voice/session.json`. Use **New Conversation** in the menu to reset on demand.

## Requirements

- macOS 13+ (built and tested on macOS 26)
- [Claude Code](https://claude.com/claude-code) installed at `~/.local/bin/claude`
- `jq` (preinstalled on recent macOS at `/usr/bin/jq`)
- Xcode Command Line Tools (`swiftc`)

## Build & install

```bash
./build.sh                                   # → build/ClaudeVoice.app (swiftc + ad-hoc codesign)

# install to a stable location (recommended) and reset its permission:
cp -R build/ClaudeVoice.app /Applications/
xattr -dr com.apple.quarantine /Applications/ClaudeVoice.app
tccutil reset Accessibility com.furqan.claudevoice
open /Applications/ClaudeVoice.app
```

The agent script must be present at `~/.claude/voice/voice-agent.sh` (executable).

## Permissions (one-time)

| Permission          | Why                                  | How |
|---------------------|--------------------------------------|-----|
| **Accessibility**   | Detect the global Right ⌘ hold       | System Settings → Privacy & Security → Accessibility → enable **ClaudeVoice**, then relaunch the app |
| **Microphone**      | Capture your voice                   | Prompted on first use → Allow |
| **Speech Recognition** | Transcribe on-device              | Prompted on first use → Allow |

> macOS activates Accessibility for a process **at launch**, so after enabling it you must **quit and relaunch** the app.

## Usage

1. Hold **Right ⌘**.
2. Speak (e.g. *"what's on my desktop"*, *"send a Teams message to Alex that I'm running late"*).
3. Release. Claude runs it and speaks the result; the card streams the words and fades.

Menu-bar icon → **New Conversation**, **Open Logs Folder…**, settings shortcuts, **Quit**.

## Configuration

- **Threading rules / system prompt** → edit `~/.claude/voice/voice-agent.sh` (`MAX_AGE`, `MAX_CTX`, `SYS`). No rebuild needed.
- **Hotkey, HUD size/position/colors, voice** → edit `Sources/main.swift` and rebuild. The trigger is `triggerKeyCode` (54 = Right ⌘).
- **Demo the HUD** without speaking a command: `open build/ClaudeVoice.app --args --demo`.

## Logs

- `~/.claude/voice/logs/agent.log` — every command, which session, token count, reply
- `~/.claude/voice/logs/agent.err` — Claude stderr

## Security note

Commands run with `--dangerously-skip-permissions` (full tool access, no confirmation) — required for unattended voice execution. A misheard command runs without a prompt. To restrict, change the `claude` flags in `voice-agent.sh`.

## Known limitations

- **Ad-hoc signed**: rebuilding the app changes its code identity, so macOS drops the Accessibility grant and you must re-grant. A self-signed signing identity would fix this permanently.
- English (`en-US`) speech + voice by default.
