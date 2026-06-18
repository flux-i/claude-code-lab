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

- `tts-server/server.py` loads Chatterbox once (on MPS) and serves on `127.0.0.1:8765`:
  - `GET /health` → `ok` once loaded.
  - `POST /tts` ({"text"} → one WAV) — **batch**: synthesizes the whole reply, then returns it. First audio only after the *entire* reply renders (~22s on a long one). This is what the app currently uses.
  - `POST /tts_stream` ({"text"} → length-framed WAVs) — **streaming**: emits one `[4-byte big-endian length][WAV]` frame per sentence chunk the instant it's ready, so playback starts in ~2.4s regardless of reply length. Built + proven via a CLI client; **not yet wired into the app** (that needs a `main.swift` change → rebuild → Accessibility re-grant). See "Streaming" below.
- The voice **conditioning is prepared once at startup** (cached `MODEL.conds`), not re-encoded per chunk — `synth_segments()` is the shared per-chunk generator both endpoints build on.
- The app **auto-launches** the server at startup (`ensureTTSServer()`) if `~/.claude/voice/tts-server/run.sh` exists and nothing is listening. First launch loads the model (~10-20s after weights are cached).
- `speak()` POSTs the text, plays the WAV via `AVAudioPlayer`, and drives the HUD karaoke window off the clip's duration (a `Timer`, since neural audio has no `willSpeakRangeOfSpeechString` callbacks).
- **Fallback:** if the server isn't reachable (still loading, not installed), `speak()` silently falls back to `speakSystem()` (Apple `AVSpeechSynthesizer`). The app always speaks *something*.

**Streaming (perceived-latency fix, server-side done).** Batch synthesis is ~1× real-time, so a long reply means ~22s of silence before the first word. `/tts_stream` fixes the *felt* latency: per-sentence chunks (`split_stream`, capped at `TTS_STREAM_MAX_CHUNK`=90 chars — the measured M3 Pro sweet spot) shipped as they finish → ~2.4s to first word, ~0.75s total gap, then gapless. It stays gapless on replies of *any* length because synth runs >1× real-time (so it never falls behind playback). Investigated alternatives and rejected them: **bf16** (~6%, noise — decode is dispatch-bound, not bandwidth-bound), and an **MLX/Chatterbox-Turbo** port (token-level streaming gives ~1.1s first-audio but sub-real-time throughput → stutters on long replies, plus a second stack). To finish: `main.swift` POSTs `/tts_stream`, reads frames into an `AVAudioPlayer` queue, paces the HUD per chunk.

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

- **Resume** if `ctx < 800k` (`HARD_MAX_CTX`) **and** (`age < 1h` (`MAX_AGE`) **or** `ctx ≤ 110k` (`OLD_OK_CTX`)).
- So a small conversation (≤110k) resumes even when it's hours old; only sessions that are *both* old *and* sizable are abandoned.
- **Context heads-up (per user):** rather than silently resetting when a conversation gets large, when a *resumed* session is past `ALERT_CTX` (400k) we speak a one-time heads-up — *"this conversation has grown to about N thousand tokens… say new conversation to start fresh"* — and let the user decide. At `HARD_MAX_CTX` (800k) we must start fresh and say so. The `alerted` flag in `session.json` makes the warning fire once. (The model window is ~1M, so 400k is a "getting large" warning, not a wall.)
- **"new conversation" voice command:** if the spoken command matches `new/fresh conversation`, `start over/fresh`, or `reset conversation`, the session state is wiped and it confirms — no agent call.

**Context size (`ctx`)** is read from the transcript's **last assistant message** — `input + cache_read + cache_creation` tokens — *not* the cumulative `claude -p` usage. The cumulative number sums cache-reads and subagent tokens across every internal step, inflating a ~50k conversation to 400k+ and tripping the cap for the wrong reason (a busy command, not a big conversation). State: `~/.claude/voice/session.json`.

## Streaming the agent (reasoning-while-it-works)

By default `voice-agent.sh` blocks on `claude -p --output-format json` and prints only the final reply — so a long task is silent until it's done. With **`VOICE_STREAM=1`** it instead runs `--output-format stream-json --verbose` and emits a tab-delimited **line protocol** on stdout so the caller can speak progress as it happens:

| line | meaning |
|---|---|
| `SAY\t<text>` | the model's own one-line narration before a step (nudged via the system prompt) |
| `TOOL\t<phrase>` | spoken fallback for a tool it's about to run (`Bash`→"running a command", etc.) |
| `ALERT\t<text>` | a heads-up (e.g. the context-size warning above) |
| `RESULT\t<text>` | the final answer |
| `SID\t<id>` | session id (internal) |

A `jq` filter turns Claude's event stream into these lines: an assistant turn that also calls a tool has interstitial narration (→ `SAY`); a text-only assistant turn is the final answer (skipped — it arrives as `result`). **Default mode is unchanged**, so the current app keeps working; streaming is consumed by the app only after the planned `main.swift` integration (read the protocol → `AVAudioPlayer` queue + HUD via `/tts_stream`, plus key-press **barge-in**: stop speaking, listen, send, resume). Test it from the CLI by piping `VOICE_STREAM=1 voice-agent.sh "…"` into a speaker harness.

## Deployment

`deploy.sh` installs the repo into `~/.claude/voice/` — symlinks `voice-agent.sh` + `tts-server/server.py`, copies `run.sh`. Run `tts-server/setup.sh` once to build the venv (it calls `deploy.sh`). The old Spokenly-dictation runner (`run-voice-command.sh`, `spokenly-hook.zsh`) has been removed — the app does its own on-device STT.
