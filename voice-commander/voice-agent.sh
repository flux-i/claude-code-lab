#!/bin/zsh
#
# voice-agent.sh — session-aware bridge between ClaudeVoice.app and Claude Code.
# ----------------------------------------------------------------------------
# Usage:  voice-agent.sh "spoken command"
# Prints Claude's reply as plain text on stdout (the app shows + speaks it).
#
# Conversation continuity:
#   CONTINUE the existing Claude session if it was last used < 1 hour ago
#   AND its context is < 300k tokens. Otherwise START A FRESH session.
#   (i.e. reset when the thread goes stale OR grows too large.)
#
# This file holds all the Claude/session logic on purpose — tweak the rules,
# thresholds, or system prompt here WITHOUT rebuilding the macOS app.

set -u

PROMPT="${1:-}"
[[ -z "${PROMPT// /}" ]] && exit 0

VOICE_DIR="$HOME/.claude/voice"
STATE="$VOICE_DIR/session.json"
LOG_DIR="$VOICE_DIR/logs"
mkdir -p "$LOG_DIR"

CLAUDE="$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Sessions in Claude Code are keyed by working directory, so always run from the
# SAME place — otherwise --resume can't find a session created elsewhere.
WORKDIR="$HOME"
cd "$WORKDIR" 2>/dev/null

MAX_AGE=3600       # 1 hour, in seconds
MAX_CTX=300000     # 300k tokens — hard ceiling: never resume a session bigger than this
OLD_OK_CTX=110000  # 100k (+10k slack): a session this small resumes even if >1h old

# True context-window size of a session = the input + cache tokens on its LAST
# assistant message in the transcript. We do NOT use the cumulative per-run usage
# from `claude -p` (it sums cache-reads and subagent tokens across every internal
# step, ballooning a ~50k conversation to 400k+ and tripping MAX_CTX for the wrong
# reason — a busy command, not a big conversation).
ctx_of_session() {
  local sid="$1"
  [[ -n "$sid" ]] || { print -r -- 0; return; }
  local proj file
  proj=$(print -r -- "$WORKDIR" | sed 's#[/.]#-#g')
  file="$HOME/.claude/projects/$proj/$sid.jsonl"
  [[ -f "$file" ]] || { print -r -- 0; return; }
  local n
  n=$(jq -r 'select(.type=="assistant" and (.message.usage!=null))
        | ((.message.usage.input_tokens // 0)
         + (.message.usage.cache_read_input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0))' "$file" 2>/dev/null | tail -1)
  print -r -- "${n:-0}"
}

now=$(date +%s)
resume=()
reason="new"

if [[ -f "$STATE" ]]; then
  sid=$(jq -r '.session_id // empty'   "$STATE" 2>/dev/null)
  last=$(jq -r '.last_used // 0'       "$STATE" 2>/dev/null)
  ctx=$(jq -r '.context_tokens // 0'   "$STATE" 2>/dev/null)
  age=$(( now - ${last:-0} ))
  # Resume when the session fits the hard ceiling AND is either recent OR small
  # enough that age stops mattering (a short conversation is cheap to resume even
  # if it's been a while). Otherwise start fresh.
  if [[ -n "$sid" ]] && (( ${ctx:-0} < MAX_CTX )) && (( age < MAX_AGE || ${ctx:-0} <= OLD_OK_CTX )); then
    resume=(--resume "$sid")
    if (( age < MAX_AGE )); then
      reason="resume (age=${age}s, ctx=${ctx})"
    else
      reason="resume (age=${age}s >1h but ctx=${ctx} ≤ ${OLD_OK_CTX} — small enough)"
    fi
  elif [[ -n "$sid" ]] && (( ${ctx:-0} >= MAX_CTX )); then
    reason="new (ctx=${ctx} ≥ ${MAX_CTX} — too large)"
  else
    reason="new (age=${age}s >1h and ctx=${ctx:-0} > ${OLD_OK_CTX} — stale)"
  fi
fi

SYS="You are a friendly voice assistant. Your replies are read aloud, so keep them concise and conversational. Do not use markdown, code blocks, bullet lists, file paths, or emojis unless explicitly asked. After doing something, confirm briefly in one or two sentences."

run_claude() {  # args: any extra flags (e.g. --resume <id>)
  "$CLAUDE" -p "$PROMPT" "$@" \
      --output-format json \
      --append-system-prompt "$SYS" \
      --dangerously-skip-permissions 2>>"$LOG_DIR/agent.err"
}

out=$(run_claude "${resume[@]}")
result=$(print -r -- "$out" | jq -r '.result // empty')

# If a resume produced nothing (stale/invalid/not-found session), retry fresh.
if [[ -z "$result" && ${#resume[@]} -gt 0 ]]; then
  reason="$reason → resume failed, starting fresh"
  out=$(run_claude)
  result=$(print -r -- "$out" | jq -r '.result // empty')
fi

sid=$(print -r -- "$out" | jq -r '.session_id // empty')
ctx=$(ctx_of_session "$sid")

# Persist session state only if we got a valid session id back.
if [[ -n "$sid" ]]; then
  print -r -- "{\"session_id\":\"$sid\",\"last_used\":$now,\"context_tokens\":${ctx:-0}}" > "$STATE"
fi

{
  print -r -- "==== $(date '+%Y-%m-%d %H:%M:%S')  [$reason] ===="
  print -r -- "PROMPT : $PROMPT"
  print -r -- "CTX    : ${ctx:-0}   SID: $sid"
  print -r -- "RESULT : $result"
  print -r -- ""
} >> "$LOG_DIR/agent.log"

print -r -- "$result"
