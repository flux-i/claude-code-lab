# CLAUDE.md — voice-commander (ClaudeVoice)

Push-to-talk macOS menu-bar app that runs spoken commands through headless Claude Code and speaks the reply back. Read this before changing things — there are a few non-obvious traps.

## Architecture (deliberate split)

```
ClaudeVoice.app  ─→  ~/.claude/voice/voice-agent.sh      →  claude -p          (shell: session logic)
 (Swift/SwiftUI)  └→  ~/.claude/voice/tts-server/run.sh   →  Chatterbox neural  (python: speech)
```

- **`Sources/main.swift`** — the entire app, single file. Hotkey + Apple `Speech` (on-device STT) + SwiftUI HUD + TTS.
- **`voice-agent.sh`** — ALL Claude/session logic lives here, on purpose (the app just shells out to it with the transcript and reads stdout). Source of truth is `voice-commander/voice-agent.sh` in the repo; `deploy.sh` symlinks it to `~/.claude/voice/voice-agent.sh`, so editing the repo file is instantly live.
- **`tts-server/`** — neural text-to-speech via Resemble AI's **Chatterbox** (local HTTP server, Python venv). The app POSTs the reply text and plays the returned WAV. See "Text-to-speech" below.

### Text-to-speech (neural, with fallback)

The reply is spoken with **Chatterbox** — an expressive open-source neural voice — not the robotic `AVSpeechSynthesizer`. How it fits together:

- `tts-server/server.py` loads Chatterbox once (on MPS) and serves `GET /health` + `POST /tts` ({"text"} → WAV) on `127.0.0.1:8765`.
- The app **auto-launches** the server at startup (`ensureTTSServer()`) if `~/.claude/voice/tts-server/run.sh` exists and nothing is listening. First launch loads the model (~10-20s after weights are cached).
- `speak()` POSTs the text, plays the WAV via `AVAudioPlayer`, and drives the HUD karaoke window off the clip's duration (a `Timer`, since neural audio has no `willSpeakRangeOfSpeechString` callbacks).
- **Fallback:** if the server isn't reachable (still loading, not installed), `speak()` silently falls back to `speakSystem()` (Apple `AVSpeechSynthesizer`). The app always speaks *something*.

Setup (one-time) and tuning:

```bash
voice-commander/tts-server/setup.sh         # one-time: build the venv, then runs deploy.sh
voice-commander/deploy.sh                    # symlink voice-agent.sh + server.py into ~/.claude/voice
~/.claude/voice/tts-server/run.sh           # run by hand to see logs (else app auto-starts it)
```

Voice character is env-controlled in the server (`TTS_EXAGGERATION`, default 0.6; `TTS_CFG`, default 0.4 — lower = more expressive; `TTS_VOICE` = path to a reference .wav for zero-shot voice cloning). Logs: `~/.claude/voice/logs/tts-server.log`.

**Why the split matters:** the app is ad-hoc signed, so every rebuild changes its code identity and macOS drops the Accessibility grant (forcing a re-grant). Keeping Claude/session behavior in the shell script means you can change the rules, prompt, or model **without rebuilding** — no permission churn. Prefer editing `voice-agent.sh` over `main.swift` whenever possible.

**Repo is the source of truth.** The shell/python pieces live in `voice-commander/` and are installed into `~/.claude/voice/` by `deploy.sh`: `voice-agent.sh` and `tts-server/server.py` are **symlinked** (edit the repo, it's live — no app rebuild), while `run.sh` is **copied** (it resolves its own dir via `${0:A:h}`, so a symlink would point back at the repo and miss the local venv). Runtime-only state (the venv, `session.json`, `logs/`) stays under `~/.claude/voice` and is never committed.

## Build / run

```bash
./build.sh                                  # swiftc + ad-hoc codesign → build/ClaudeVoice.app
open build/ClaudeVoice.app                  # run
open build/ClaudeVoice.app --args --demo    # cycle the HUD (no mic/permissions needed)
pkill -9 -f ClaudeVoice                     # stop
```

Always `pkill` before relaunching. Build target is `arm64-apple-macos26.0`, language mode `-swift-version 5` (avoids Swift 6 strict-concurrency errors). The `synth` non-Sendable warning is expected/harmless.

## Install for real use

```bash
cp -R build/ClaudeVoice.app /Applications/
xattr -dr com.apple.quarantine /Applications/ClaudeVoice.app
tccutil reset Accessibility com.furqan.claudevoice
open /Applications/ClaudeVoice.app
```

Run from `/Applications` (stable path → no app-translocation breaking TCC). Bundle id: `com.furqan.claudevoice`.

## Traps (these have all bitten us)

1. **Accessibility + ad-hoc signing.** The grant is honored only for the exact binary that was granted. Rebuild → re-grant. macOS activates Accessibility **at launch**, so after toggling it you must relaunch. If "granted" shows ON but isn't honored, `tccutil reset Accessibility com.furqan.claudevoice` and re-grant from `/Applications`.
2. **Sessions are keyed by working directory.** `voice-agent.sh` MUST `cd "$HOME"` before calling `claude`, or `--resume <id>` fails with "No conversation found" when the app spawns it from `/`. It also falls back to a fresh session if a resume returns empty — keep that fallback.
3. **Hotkey is a bare modifier** (Right ⌘, keyCode 54) → detected via `NSEvent` global `.flagsChanged` monitor, which *requires* Accessibility. A bare modifier cannot be a Carbon hotkey; don't "simplify" it to `RegisterEventHotKey`.
4. **Don't block the main thread** on `claude` (it takes seconds). Execution runs on a background queue; UI/state updates dispatch back to main.
5. **TTS server is a separate process** under `~/.claude/voice/tts-server` (its own Python 3.11 venv, ~torch). It is NOT bundled in the app and survives rebuilds — `~/.claude/voice/tts-server/server.py` is a symlink to `voice-commander/tts-server/server.py`, so editing the repo file is live; just restart the server to reload (`pkill -f server.py; ~/.claude/voice/tts-server/run.sh &`). No app rebuild needed. If speech sounds like the old robotic voice, the server is down/loading → check `~/.claude/voice/logs/tts-server.log` and `curl 127.0.0.1:8765/health`. The model load on first launch takes ~10-20s; until then replies use the Apple fallback voice.

## HUD / UX invariants (per user)

- Compact card, **top-right under the menu bar** (`visibleFrame`, 360×92). Not centered, not large.
- **No "Done" state** — the reply phase shows only the orb + streamed text.
- Reply is **streamed in a rolling ~10-word window synced to TTS**, never dumped in full. Card fades when speech ends. (Neural path: a `Timer` paces the window off the clip duration; system-fallback path: `willSpeakRangeOfSpeechString`.)
- Orb colors: blue=listening, violet=thinking, green=speaking, rose=error.

## Conversation rule

Resume the stored session when it fits the hard ceiling **and** is either recent or small enough that age stops mattering — otherwise start fresh. Concretely (`voice-agent.sh`):

- **Resume** if `ctx < 300k` (`MAX_CTX`, hard ceiling) **and** (`age < 1h` (`MAX_AGE`) **or** `ctx ≤ 110k` (`OLD_OK_CTX`)).
- So a small conversation (≤110k) resumes even when it's hours old; only sessions that are *both* old *and* sizable are abandoned.

**Context size (`ctx`)** is read from the transcript's **last assistant message** — `input + cache_read + cache_creation` tokens — *not* the cumulative `claude -p` usage. The cumulative number sums cache-reads and subagent tokens across every internal step, inflating a ~50k conversation to 400k+ and tripping the cap for the wrong reason (a busy command, not a big conversation). State: `~/.claude/voice/session.json`.

## Deployment

`deploy.sh` installs the repo into `~/.claude/voice/` — symlinks `voice-agent.sh` + `tts-server/server.py`, copies `run.sh`. Run `tts-server/setup.sh` once to build the venv (it calls `deploy.sh`). The old Spokenly-dictation runner (`run-voice-command.sh`, `spokenly-hook.zsh`) has been removed — the app does its own on-device STT.
