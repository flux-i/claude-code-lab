#!/bin/zsh
# One-time setup: build the whisper.cpp speech-to-text server into
# ~/.claude/voice/stt-server. Mirrors tts-server/setup.sh — code/assets live under
# ~/.claude/voice so the server can change without rebuilding the ad-hoc-signed app
# (which would otherwise drop the Accessibility grant; see CLAUDE.md).
#
# Builds whisper.cpp with Metal (Apple-Silicon GPU) and downloads large-v3-turbo —
# English, the most accent-robust open Whisper variant, ~6x faster than large-v3.
# Needs: git, cmake, Xcode command-line tools (already present — you build with swiftc).
set -euo pipefail

SRC="${0:A:h}"
DEST="$HOME/.claude/voice/stt-server"
MODEL_NAME="${STT_MODEL_NAME:-large-v3-turbo-q5_0}"   # q8_0 = accuracy knob

# Install the launcher (deploy.sh copies run.sh into ~/.claude/voice/stt-server).
echo "→ installing scripts via deploy.sh"
"$SRC/../deploy.sh"

cd "$DEST"

if [[ ! -d whisper.cpp ]]; then
  echo "→ cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
fi
cd whisper.cpp

echo "→ building whisper-server (Metal)"
cmake -B build -DGGML_METAL=ON
cmake --build build -j --config Release

echo "→ downloading model: $MODEL_NAME"
sh ./models/download-ggml-model.sh "$MODEL_NAME"

echo "✓ setup complete. Start it with:  $DEST/run.sh"
