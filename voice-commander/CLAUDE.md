# CLAUDE.md — voice-commander (ClaudeVoice)

Push-to-talk macOS menu-bar app that runs spoken commands through headless Claude Code and speaks the reply back. Read this before changing things — there are a few non-obvious traps.

## Architecture (deliberate split)

```
ClaudeVoice.app  ─→  ~/.claude/voice/voice-agent.sh      →  claude -p          (shell: session logic)
 (Swift/SwiftUI)  ├→  ~/.claude/voice/tts-server/run.sh   →  Chatterbox neural  (python: TTS)
                  └→  ~/.claude/voice/stt-server/run.sh   →  whisper.cpp        (c++:    STT)
```

- **`Sources/main.swift`** — the entire app, single file. Hotkey + speech-to-text (Whisper primary, Apple `Speech` fallback) + SwiftUI HUD + TTS.
- **`voice-agent.sh`** — ALL Claude/session logic lives here, on purpose (the app just shells out to it with the transcript and reads stdout). Source of truth is `voice-commander/voice-agent.sh` in the repo; `deploy.sh` symlinks it to `~/.claude/voice/voice-agent.sh`, so editing the repo file is instantly live.
- **`tts-server/`** — neural text-to-speech via Resemble AI's **Chatterbox** (local HTTP server, Python venv). The app POSTs the reply text and plays the returned WAV. See "Text-to-speech" below.
- **`stt-server/`** — speech-to-text via **whisper.cpp** (`large-v3-turbo`, local HTTP server, no Python — the prebuilt `whisper-server` binary *is* the server). The app POSTs the recorded WAV and uses the returned transcript. See "Speech-to-text" below.

### Startup launcher (servers run only while the app is open)

The app opens to a **startup window** (`LauncherView` in `main.swift`) — it does **not** auto-start the servers anymore. Flow: **Start** → launches the TTS + STT servers and polls them (`pollLauncherHealth`) showing per-server *Starting…/Ready* → once both are healthy the button becomes **Enter ClaudeVoice** → that switches the app from `.regular` to `.accessory` (menu-bar mode) and the push-to-talk hotkey goes live (gated on `didProceed`). The servers are **owned by the app**: ones it launched are kept as `ttsProc`/`sttProc`, and a server already listening at Start (warm leftover) is **adopted** by PID (`pidListening` via `lsof`) into `adoptedPIDs`. `applicationWillTerminate` → `stopServers()` SIGTERMs all of them, so **quitting ClaudeVoice stops the servers** — nothing lingers in the background. (`run.sh` `exec`s the server, so the Process PID *is* the server and SIGTERM reaches it directly.) `--demo` skips the launcher (goes straight to accessory mode).

### Speech-to-text (Whisper primary, Apple fallback — hybrid)

Push-to-talk audio is transcribed by **Whisper** (`whisper.cpp`, `large-v3-turbo`) running
as a local server, with Apple's on-device `SFSpeechRecognizer` kept underneath. Whisper was
chosen for **accent robustness** (English): on the user's own corpus, Apple on-device mangled
domain proper nouns (`LangFuse`→"length fuse", `Codex`→"Kotex") and silently dropped some
longer clips. How the two engines combine (`main.swift`):

- The hotkey-down path **always** starts `SFSpeechRecognizer` (live partial words → the HUD)
  **and**, when the Whisper server is up, simultaneously records the mic to a 16 kHz mono WAV
  (`beginWavCapture`/`appendWav`, via `AVAudioConverter`).
- On key-up: if Whisper is up, the WAV is POSTed to `whisper-server` `/inference`
  (`transcribeWithWhisper`/`postWhisper`, multipart, `response_format=json`, `language=en`) and
  its transcript is used; **if the POST fails or returns empty, the live Apple transcript is the
  fallback**. If the server is down at key-down, the turn is Apple-only (today's behavior, incl.
  the 2 s silence timeout). The per-turn route is `usingWhisper`, decided from a cached `sttUp`.
- **Liveness:** `whisper-server` has no `/health`; once the port answers, the model is already
  loaded. `pollSTTHealth()` refreshes the cached `sttUp` every 3 s so key-down has zero
  health-check latency. The server is launched from the **startup launcher's Start button**
  (`ensureSTTServer()`), same as the TTS one; first launch loads the model (~10-20s) and the
  launcher shows *Starting…* until the port answers (and once in use, commands fall back to Apple
  if the server isn't up).
- **Barge-in:** the Whisper POST completion is guarded on `runID` (like the TTS path), so a
  superseded turn's transcript is dropped.

See `stt-server/README.md` for setup and tuning (model/quantization, threads). Logs:
`~/.claude/voice/logs/stt-server.log`.

### Text-to-speech (neural, with fallback)

The reply is spoken with **Chatterbox** — an expressive open-source neural voice — not the robotic `AVSpeechSynthesizer`. How it fits together:

- `tts-server/server.py` loads Chatterbox once (on MPS) and serves on `127.0.0.1:8765`:
  - `GET /health` → `ok` once loaded.
  - `POST /tts` ({"text"} → one WAV) — **batch**: synthesizes the whole reply, then returns it. First audio only after the *entire* reply renders (~22s on a long one). Used for short **narration** segments (SAY/TOOL/ALERT, the "On it…" ack), which are single lines.
  - `POST /tts_stream` ({"text"} → length-framed WAVs) — **streaming**: emits one `[4-byte big-endian length][WAV]` frame per chunk the instant it's ready, so playback starts in ~3-5s regardless of reply length. **This is what the app uses for the final answer** (`startResultStream` in `main.swift`). See "Streaming" below.
- The voice **conditioning is prepared once at startup** (cached `MODEL.conds`), not re-encoded per chunk — `synth_segments()` is the shared per-chunk generator both endpoints build on.
- The server is launched from the **startup launcher's Start button** (`ensureTTSServer()`) if `~/.claude/voice/tts-server/run.sh` exists and nothing is listening. First launch loads the model (~10-20s after weights are cached; a cold load can be longer — the launcher waits on `/health` before showing *Ready*).
- `speak()` POSTs the text, plays the WAV via `AVAudioPlayer`, and drives the HUD karaoke window off the clip's duration (a `Timer`, since neural audio has no `willSpeakRangeOfSpeechString` callbacks).
- **Fallback:** if the server isn't reachable (still loading, not installed), `speak()` silently falls back to `speakSystem()` (Apple `AVSpeechSynthesizer`). The app always speaks *something*.

**Streaming (perceived-latency fix, wired end-to-end).** Batch synthesis is ~1× real-time, so rendering a long reply whole means ~20-34s of silence before the first word. `/tts_stream` fixes the *felt* latency: the reply is chunked (`split_stream`) and each chunk ships the instant it's synthesized → first word in ~3-5s on any length, then continuous.

- **No mid-stream catches (the smoothing tweak).** Synth runs ~1.2-1.6× real-time *once going*, but the very first chunk→second-chunk hand-off used to underrun when the opening sentence was short (its playback ended before the next chunk finished synthesizing — an audible ~0.5s catch). Fix: `split_stream` packs a **slightly larger first chunk** (`TTS_STREAM_FIRST`=95 chars) so its playback covers the next chunk's synth time and builds a lead, then small uniform **body chunks** (`TTS_STREAM_CHUNK`=60) hold that lead. Measured on M3 Pro: zero catches across short/medium/long, ~3-5s first word. (Verify with `/tmp/tts_probe.py`-style framing reads: inter-arrival ≈ per-chunk synth time; `play_start` gap should be 0.)
- **App side (`main.swift`, `startResultStream`).** The final answer (`RESULT`) is streamed: a `URLSession` (the app is its `URLSessionDataDelegate`) reads `[len][WAV]` frames into `streamChunks`, played gaplessly via chained `AVAudioPlayer`s — the **next** chunk's player is `prepareToPlay`'d while the current one plays so transitions are seamless (`playNextStreamChunk`/`prepareNextStreamChunk`). If narration/ack is still playing when `RESULT` lands it's held in `pendingResult` and started when the batch queue drains. Underrun (no chunk ready) just waits for the next frame; `streamEOF` + empty queue ⇒ `finishStreamResult`. Barge-in tears it all down (cancel task, invalidate session, clear buffers) under the same `runID` guard. HUD karaoke runs off an *estimated* total duration (`estimatedSpeechDuration`, ~0.072 s/char) since the real one isn't known until every frame lands. Fallback: if the server sends no audio, `speakSystem` (Apple voice).
- **Rejected alternatives:** **bf16** (~6%, noise — decode is dispatch-bound, not bandwidth-bound); an **MLX/Chatterbox-Turbo** port (token-level streaming gives ~1.1s first-audio but sub-real-time throughput → stutters on long replies, plus a second stack); and **render-all-then-speak** (perfectly smooth but ~11s/34s of upfront silence on medium/long replies — streaming wins on felt latency).

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
6. **STT server is a separate process** under `~/.claude/voice/stt-server` (a built `whisper.cpp`, no Python). Like the TTS server it is NOT bundled and survives rebuilds; restart with `pkill -f whisper-server; ~/.claude/voice/stt-server/run.sh &`. If transcripts look like the old Apple mistakes (mangled proper nouns), the Whisper server is down/loading → check `~/.claude/voice/logs/stt-server.log` and `curl 127.0.0.1:8766/` (any HTTP response = up); until it answers, the app transcribes with the Apple fallback. The model is **not** committed — re-run `stt-server/setup.sh` on a fresh machine.

## HUD / UX invariants (per user)

- Compact card, **top-right under the menu bar** (`visibleFrame`, 360×92). Not centered, not large.
- **No "Done" state** — the reply phase shows only the orb + streamed text.
- Reply is **streamed in a rolling ~10-word window synced to TTS**, never dumped in full. Card fades when speech ends. (Neural path: a `Timer` paces the window off the clip duration; system-fallback path: `willSpeakRangeOfSpeechString`.)
- Orb colors: blue=listening, violet=thinking, green=speaking, rose=error.

## Model & reasoning routing (the dispatcher)

Every command is first sent to a fast **router** LLM (`claude -p --model sonnet --effort medium`, env: `VOICE_ORCH_MODEL`/`VOICE_ORCH_EFFORT`) that returns one minified JSON object — `{model, effort, mode, prompt, reason}` — deciding how to run the *worker*. It's a pure classifier: `--system-prompt` (not `--append-`) **replaces** Claude Code's large default prompt with just the catalog, `--allowed-tools ''` loads **no tools**, and `--no-session-persistence` keeps it from creating a session — so it's cheap and can't try to *do* the task. It knows the model catalog (haiku/sonnet/opus — capability, speed, cost) and the effort levels, honors explicit directives in the command ("use opus", "xhigh", "quick"), and otherwise picks by difficulty (trivial→haiku, ordinary→sonnet/high, hard→opus/high·xhigh). The worker is then `claude -p --model <m> [--effort <e>] [--resume …]` with the directive stripped from the prompt. Set `VOICE_ROUTER=0` to bypass the router (falls back to `VOICE_DEFAULT_MODEL`/`_EFFORT` = sonnet/high + the ctx/age heuristic below).

- **Validity clamps (the CLI 400s otherwise):** `haiku` takes **no** `--effort`; `xhigh` is **opus-only** (clamped to `high` for sonnet/haiku). The router is told both rules; `voice-agent.sh` enforces them as a safety net.
- **Cost:** the router adds one fast `claude` round-trip before the worker on every command (the app's "On it." ack covers the gap).

## Conversation rule

The **router decides resume vs. new** from intent, but two deterministic guardrails always win (`voice-agent.sh`):

- **Hard cap:** at `ctx ≥ 800k` (`HARD_MAX_CTX`) we force a fresh session regardless of the router; no prior session likewise ⇒ new.
- **"new conversation" voice command:** if the spoken command matches `new/fresh conversation`, `start over/fresh`, or `reset conversation`, the session state is wiped and it confirms — *before* the router even runs (no agent call).
- **Router disabled/unparseable → ctx/age heuristic fallback:** resume if `ctx < 800k` **and** (`age < 1h` (`MAX_AGE`) **or** `ctx ≤ 110k` (`OLD_OK_CTX`)) — so a small conversation (≤110k) resumes even when hours old; only sessions that are *both* old *and* sizable are abandoned.
- **Context heads-up (per user):** when a *resumed* session is past `ALERT_CTX` (400k) we speak a one-time heads-up — *"this conversation has grown to about N thousand tokens… say new conversation to start fresh"* — and let the user decide. At `HARD_MAX_CTX` (800k) we must start fresh and say so. The `alerted` flag in `session.json` makes the warning fire once. (The model window is ~1M, so 400k is a "getting large" warning, not a wall.)

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

A `jq` filter turns Claude's event stream into these lines: an assistant turn that also calls a tool has interstitial narration (→ `SAY`); a text-only assistant turn is the final answer (skipped — it arrives as `result`). **Default mode is unchanged**, so the script stays CLI-testable: pipe `VOICE_STREAM=1 voice-agent.sh "…"` into a speaker harness.

**The app consumes this protocol (`main.swift`).** `runClaude` launches the agent with `VOICE_STREAM=1`, reads stdout **line by line as it streams**, and feeds each `SAY/TOOL/ALERT` line into a **speech queue** (`enqueueSpeech` → `playNextInQueue` → `speakSegment`) that speaks one short narration segment at a time via the batch `/tts`, advancing on each `audioPlayerDidFinishPlaying`. The final `RESULT`, however, is **streamed gaplessly via `/tts_stream`** (`startResultStream`; see "Streaming" above) rather than split into sentences client-side — one continuous reply, first word in ~3-5s. If narration/ack is still playing when `RESULT` arrives it waits in `pendingResult` and starts when the queue drains. An immediate `"On it."` ack is enqueued at send so silence breaks at once (the first model narration can be ~10s out). Orb: violet (`.thinking`) while waiting on the agent, green (`.done`) while audio plays.

**Barge-in.** Press the hotkey while a response is thinking or speaking and `startRecording` calls `cancelCurrentOperation()` — it `terminate()`s the in-flight agent, stops audio, clears the queue, and bumps a **`runID`** generation token so any late callbacks from the old turn are dropped — then starts a fresh listen. Releasing the key sends the new command, and the response voice resumes via the queue. Every async callback (`dispatchProtocolLine`, `speakSegment` completion, agent exit) guards on `myID == runID` so a superseded turn can never leak audio into the new one.

## Deployment

`deploy.sh` installs the repo into `~/.claude/voice/` — symlinks `voice-agent.sh` + `tts-server/server.py`, copies both `run.sh` launchers (TTS + STT). Run `tts-server/setup.sh` once to build the venv and `stt-server/setup.sh` once to build whisper.cpp + download the model (both call `deploy.sh`). The STT runtime (`whisper.cpp/` build + `*.bin` model) lives only under `~/.claude/voice/stt-server/` and is never committed — same convention as the Python venv. The old Spokenly-dictation runner (`run-voice-command.sh`, `spokenly-hook.zsh`) has been removed; the app now transcribes locally via Whisper, with Apple on-device STT as the fallback (see "Speech-to-text").
