#!/bin/zsh
# Launch the Chatterbox TTS server from its installed location.
# The app calls this at startup; you can also run it by hand to see logs.
set -euo pipefail
DIR="${0:A:h}"
cd "$DIR"
# Voice character: clone the reference clip if present (female voice seed). Drop a
# different reference.wav here (5-15s of clean speech) to change who Claude sounds like.
if [[ -f "$DIR/reference.wav" ]]; then
  export TTS_VOICE="$DIR/reference.wav"
fi
exec .venv/bin/python server.py
