#!/bin/zsh
# One-time setup: install the Chatterbox TTS server into ~/.claude/voice/tts-server.
#
# Mirrors the project's "logic/assets live under ~/.claude/voice, the app shells
# out" convention (see CLAUDE.md), so the server can be changed without rebuilding
# the ad-hoc-signed app (which would otherwise drop the Accessibility grant).
#
# Uses Python 3.11 (most reliable for torch wheels) via `uv`.
set -euo pipefail

SRC="${0:A:h}"
DEST="$HOME/.claude/voice/tts-server"

# Install the code (symlinks server.py, copies run.sh + the voice reference). deploy.sh
# is the single place that wires the repo into ~/.claude/voice.
echo "→ installing code via deploy.sh"
"$SRC/../deploy.sh"

cd "$DEST"

echo "→ creating venv (python 3.11)"
uv venv --python 3.11 .venv

echo "→ installing chatterbox-tts (this downloads PyTorch — a few minutes)"
# setuptools<81: chatterbox's `perth` watermarker imports `pkg_resources`, which
# setuptools removed in 81. uv venvs don't bundle setuptools, so pin it explicitly.
VIRTUAL_ENV="$DEST/.venv" uv pip install "chatterbox-tts" numpy "setuptools<81"

echo "✓ setup complete. Start it with:  $DEST/run.sh"
