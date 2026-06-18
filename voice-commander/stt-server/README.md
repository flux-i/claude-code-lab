# stt-server — local Whisper speech-to-text (whisper.cpp)

Primary speech-to-text for ClaudeVoice. The app records your push-to-talk audio to a
16 kHz mono WAV and POSTs it to a local **whisper.cpp** `whisper-server`; the returned
transcript is what gets run. Apple's on-device `SFSpeechRecognizer` still runs
underneath for the live partial-word HUD and as an offline fallback when this server is
down (see CLAUDE.md → "Speech-to-text").

**Model:** `large-v3-turbo` — English, the most accent-robust open Whisper variant,
~6× faster than `large-v3`. Fully offline, free, Metal-accelerated.

## Setup (one-time)

```bash
voice-commander/stt-server/setup.sh     # clones + builds whisper.cpp (Metal), downloads the model
~/.claude/voice/stt-server/run.sh       # run by hand to watch logs (else the app auto-starts it)
```

`setup.sh` calls `deploy.sh`, then builds `whisper.cpp` and downloads
`ggml-large-v3-turbo-q5_0.bin` (~547 MiB) into `~/.claude/voice/stt-server/`. The build,
binary, and model are runtime-only — never committed (only `run.sh`/`setup.sh`/this
README live in the repo).

## Endpoint

`whisper-server` serves `POST /inference` (multipart form, field `file` = a 16 kHz mono
WAV; `response_format=json` → `{"text": ...}`). Listens on `127.0.0.1:8766`.

```bash
curl -F file=@clip.wav -F response_format=json -F temperature=0 \
     127.0.0.1:8766/inference
```

## Tuning (env vars read by run.sh)

| var | default | meaning |
|---|---|---|
| `STT_PORT` | `8766` | listen port (must match `sttPort` in main.swift) |
| `STT_MODEL` | `…/ggml-large-v3-turbo-q5_0.bin` | path to the ggml model |
| `STT_THREADS` | `8` | CPU threads for non-GPU work |

Accuracy knob: re-run `setup.sh` with `STT_MODEL_NAME=large-v3-turbo-q8_0` (834 MiB) or
`large-v3` (3.1 GB) and point `STT_MODEL` at it. Speed knob: add `-fa` (flash attention)
to the `whisper-server` invocation in `run.sh`.

Logs: `~/.claude/voice/logs/stt-server.log`.
