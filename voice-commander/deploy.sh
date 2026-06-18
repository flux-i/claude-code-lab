#!/bin/zsh
# deploy.sh — install the voice-commander runtime into ~/.claude/voice (where the
# ClaudeVoice app reads it at runtime).
#
# The repo is the source of truth. Files we actively edit (voice-agent.sh and
# tts-server/server.py) are SYMLINKED, so editing them in the repo is instantly live
# with no copy step and no app rebuild. run.sh is COPIED, not symlinked, because it
# resolves its own directory via ${0:A:h} — a symlink would resolve back to the repo
# and miss the local .venv. Runtime state (the Python venv, session.json, logs/) is
# created/owned locally by tts-server/setup.sh and never lives in the repo.
#
# Safe to re-run anytime. Run tts-server/setup.sh once first to build the venv.
set -euo pipefail

HERE="${0:A:h}"                       # voice-commander/ in the repo
VOICE="$HOME/.claude/voice"
mkdir -p "$VOICE/tts-server" "$VOICE/stt-server" "$VOICE/logs"

# Source-of-truth files → symlinks (edit the repo, it's instantly live).
ln -sf "$HERE/voice-agent.sh"        "$VOICE/voice-agent.sh"
ln -sf "$HERE/tts-server/server.py"  "$VOICE/tts-server/server.py"

# run.sh must be a real file here (see header). Copy it + the voice reference.
cp "$HERE/tts-server/run.sh" "$VOICE/tts-server/run.sh"
chmod +x "$VOICE/tts-server/run.sh"
[[ -f "$HERE/tts-server/reference.wav" ]] && cp "$HERE/tts-server/reference.wav" "$VOICE/tts-server/reference.wav"

# STT server (whisper.cpp): only run.sh lives in the repo — the binary + model are
# built locally by stt-server/setup.sh under $VOICE/stt-server. run.sh is copied for
# the same ${0:A:h} reason as the TTS one (no editable source to symlink).
cp "$HERE/stt-server/run.sh" "$VOICE/stt-server/run.sh"
chmod +x "$VOICE/stt-server/run.sh"

echo "deployed → $VOICE"
echo "  voice-agent.sh        → $(readlink "$VOICE/voice-agent.sh")"
echo "  tts-server/server.py  → $(readlink "$VOICE/tts-server/server.py")"
echo "  tts-server/run.sh     (copy)"
echo "  stt-server/run.sh     (copy)"
echo "Restart the TTS server to pick up a server.py change:  pkill -f server.py; $VOICE/tts-server/run.sh &"
