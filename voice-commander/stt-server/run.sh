#!/bin/zsh
# Launch the whisper.cpp speech-to-text server from its installed location.
# The app calls this at startup (ensureSTTServer); you can also run it by hand to
# watch logs. whisper-server exposes POST /inference (multipart form, field "file"
# = a 16 kHz mono WAV) → JSON {"text": ...}. Metal (Apple-Silicon GPU) is on by default.
#
# Must be a real file here (not a symlink): it resolves its own dir via ${0:A:h} to
# find the locally-built binary + model under ~/.claude/voice/stt-server, which a
# symlink back to the repo would miss. (Same rule as tts-server/run.sh.)
set -euo pipefail
DIR="${0:A:h}"
cd "$DIR"

WHISPER_DIR="$DIR/whisper.cpp"
BIN="$WHISPER_DIR/build/bin/whisper-server"
MODEL="${STT_MODEL:-$WHISPER_DIR/models/ggml-large-v3-turbo-q5_0.bin}"
PORT="${STT_PORT:-8766}"
THREADS="${STT_THREADS:-8}"

if [[ ! -x "$BIN" ]]; then
  echo "whisper-server not built — run stt-server/setup.sh first" >&2
  exit 1
fi
if [[ ! -f "$MODEL" ]]; then
  echo "model not found: $MODEL — run stt-server/setup.sh first" >&2
  exit 1
fi

# -l en          force English (we only want English; skips language detection)
# -t THREADS     CPU threads for the non-GPU parts
# Tuning knobs (see README): swap MODEL to *-q8_0 or large-v3 for accuracy, add -fa
# for flash-attention speed.
exec "$BIN" \
  -m "$MODEL" \
  --host 127.0.0.1 --port "$PORT" \
  -l en \
  -t "$THREADS"
