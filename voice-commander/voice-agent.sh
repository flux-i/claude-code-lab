#!/bin/zsh
#
# voice-agent.sh — session-aware bridge between ClaudeVoice.app and Claude Code.
# ----------------------------------------------------------------------------
# Usage:  voice-agent.sh "spoken command"
#
# Two output modes:
#   • default (VOICE_STREAM unset/0): blocks, prints Claude's final reply on
#     stdout as plain text (what the app currently consumes).
#   • streaming (VOICE_STREAM=1): consumes Claude's stream-json events and emits a
#     tab-delimited LINE PROTOCOL on stdout so the caller can speak progress as it
#     happens instead of waiting in silence:
#        SAY\t<text>      the model's own one-line narration before a step
#        TOOL\t<phrase>   a spoken phrase for a tool it's about to run
#        ALERT\t<text>    a heads-up (e.g. the conversation is getting large)
#        RESULT\t<text>   the final answer
#        SID\t<id>        the session id (internal; caller can ignore)
#
# Conversation continuity:
#   RESUME the existing session if it was last used < 1h ago AND its context is
#   under the hard cap; small sessions resume even when old. At ALERT_CTX we warn
#   the user (once) that it's getting large; at HARD_MAX_CTX we must start fresh
#   and say so. The user can also say "new conversation" to reset on demand.
#
# All Claude/session logic lives here on purpose — tweak rules, thresholds, the
# system prompt, or the narration WITHOUT rebuilding the macOS app.

set -u

PROMPT="${1:-}"
[[ -z "${PROMPT// /}" ]] && exit 0

VOICE_DIR="$HOME/.claude/voice"
STATE="${VOICE_STATE:-$VOICE_DIR/session.json}"   # override for tests
LOG_DIR="$VOICE_DIR/logs"
mkdir -p "$LOG_DIR"

CLAUDE="$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Sessions in Claude Code are keyed by working directory, so always run from the
# SAME place — otherwise --resume can't find a session created elsewhere.
WORKDIR="$HOME"
cd "$WORKDIR" 2>/dev/null

STREAM="${VOICE_STREAM:-0}"     # 1 => emit the SAY/TOOL/ALERT/RESULT line protocol

MAX_AGE=3600          # 1 hour — staleness cutoff for resuming
HARD_MAX_CTX=800000   # 800k — never resume beyond this; force fresh and announce it
ALERT_CTX=400000      # 400k — warn (once) that the conversation is getting large
OLD_OK_CTX=110000     # 100k (+10k): a session this small resumes even if >1h old

emit() {                                  # one protocol line (real tab delimiter)
  print -r -- "$1"$'\t'"$2"
  [[ "$STREAM" == "1" ]] && print -r -- "$(date '+%H:%M:%S')  $1  $2" >> "$LOG_DIR/protocol.log"
}

# ---- voice command: start a new conversation on demand ----------------------
if [[ "${PROMPT:l}" =~ '(new|fresh) (conversation|chat)|start (over|fresh)|reset( the)? (conversation|chat)' ]]; then
  rm -f "$STATE"
  msg="Okay, starting a fresh conversation. What would you like to do?"
  if [[ "$STREAM" == "1" ]]; then emit RESULT "$msg"; else print -r -- "$msg"; fi
  exit 0
fi

# True context-window size of a session = input + cache tokens on its LAST assistant
# message in the transcript. NOT the cumulative per-run usage from `claude -p` (that
# sums cache-reads + subagent tokens across every internal step, ballooning a ~50k
# conversation to 400k+ and tripping the cap for the wrong reason).
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
prev_ctx=0
alerted=0
forced_reset=0

if [[ -f "$STATE" ]]; then
  sid=$(jq -r '.session_id // empty' "$STATE" 2>/dev/null)
  last=$(jq -r '.last_used // 0'     "$STATE" 2>/dev/null)
  ctx=$(jq -r '.context_tokens // 0' "$STATE" 2>/dev/null)
  alerted=$(jq -r '.alerted // 0'    "$STATE" 2>/dev/null)
  prev_ctx=${ctx:-0}
  age=$(( now - ${last:-0} ))
  if [[ -n "$sid" ]] && (( prev_ctx < HARD_MAX_CTX )) && (( age < MAX_AGE || prev_ctx <= OLD_OK_CTX )); then
    resume=(--resume "$sid")
    reason="resume (age=${age}s ctx=${prev_ctx})"
  elif [[ -n "$sid" ]] && (( prev_ctx >= HARD_MAX_CTX )); then
    reason="new (ctx=${prev_ctx} ≥ HARD_MAX — forced reset)"
    forced_reset=1
  else
    reason="new (age=${age}s stale)"
  fi
fi

# Context heads-up: resuming a session that has grown past ALERT_CTX (warn once), or
# a forced reset at the hard cap. Spoken before the answer so the user hears it first.
context_alert=""
if [[ ${#resume[@]} -gt 0 ]] && (( prev_ctx >= ALERT_CTX )) && (( alerted == 0 )); then
  context_alert="Heads up — this conversation has grown to about $(( prev_ctx / 1000 )) thousand tokens. I can keep going, or say \"new conversation\" to start fresh."
  alerted=1
elif (( forced_reset == 1 )); then
  context_alert="This conversation hit its size limit, so I've started a fresh one."
  alerted=0
fi

SYS="You are a friendly voice assistant. Your replies are read aloud, so keep them concise and conversational. Do not use markdown, code blocks, bullet lists, file paths, or emojis unless explicitly asked. After doing something, confirm briefly in one or two sentences. Do NOT add greetings or sign-offs (no \"talk to you later\", \"let me know\", etc.) — just answer."
if [[ "$STREAM" == "1" ]]; then
  SYS="$SYS If a task takes several steps, you MAY occasionally say one short progress note at the start of a significant step — only when it genuinely tells the user something useful. Never narrate routine or repeated commands, never restate your answer in a note, and keep notes rare; most requests need none at all. Your final message is only the answer."
fi

# jq: transform Claude's stream-json events into our line protocol. An assistant
# message that ALSO calls a tool has interstitial narration text (speak it); a
# text-only assistant message is the final answer (skip — it arrives as `result`).
JQ_PROTO='
  if .type=="system" and .subtype=="init" then "SID\t" + (.session_id // "")
  elif .type=="assistant" then
    (.message.content // []) as $c |
    if (any($c[]; .type=="tool_use")) then
      ($c[] | select(.type=="text") | (.text|gsub("\n";" ")) | select(test("\\S")) | "SAY\t" + .),
      ($c[] | select(.type=="tool_use") | "TOOL\t" + (.name // ""))
    else empty end
  elif .type=="result" then
    ("SID\t" + (.session_id // "")), ("RESULT\t" + (.result // ""))
  else empty end
'

result=""
sid_seen=""

run_stream() {  # consume events; fill result/sid_seen; emit SAY/TOOL live (stream mode)
  while IFS=$'\t' read -r tag rest; do
    case "$tag" in
      SID)    [[ -n "$rest" ]] && sid_seen="$rest" ;;
      SAY)    emit SAY "$rest" ;;     # only the model's OWN narration is spoken
      TOOL)   : ;;                    # tool-phrase fallback removed — too repetitive ("running a command…")
      RESULT) result="$rest" ;;
    esac
  done < <( "$CLAUDE" -p "$PROMPT" "$@" \
              --output-format stream-json --verbose \
              --append-system-prompt "$SYS" \
              --dangerously-skip-permissions 2>>"$LOG_DIR/agent.err" \
            | jq -rc --unbuffered "$JQ_PROTO" )
}

run_json() {  # default: block, capture full json, extract result (live-app contract)
  local out
  out=$("$CLAUDE" -p "$PROMPT" "$@" \
          --output-format json \
          --append-system-prompt "$SYS" \
          --dangerously-skip-permissions 2>>"$LOG_DIR/agent.err")
  result=$(print -r -- "$out" | jq -r '.result // empty')
  sid_seen=$(print -r -- "$out" | jq -r '.session_id // empty')
}

# Speak the context alert first (stream mode emits it now; default mode prepends it
# to the result at the end).
[[ -n "$context_alert" && "$STREAM" == "1" ]] && emit ALERT "$context_alert"

if [[ "$STREAM" == "1" ]]; then run_stream "${resume[@]}"; else run_json "${resume[@]}"; fi

# Resume produced nothing (stale/invalid session) -> retry fresh.
if [[ -z "$result" && ${#resume[@]} -gt 0 ]]; then
  reason="$reason → resume failed, fresh"
  resume=()
  if [[ "$STREAM" == "1" ]]; then run_stream; else run_json; fi
fi

sid="$sid_seen"
ctx=$(ctx_of_session "$sid")

# Persist session state only if we got a valid session id back.
if [[ -n "$sid" ]]; then
  print -r -- "{\"session_id\":\"$sid\",\"last_used\":$now,\"context_tokens\":${ctx:-0},\"alerted\":${alerted}}" > "$STATE"
fi

{
  print -r -- "==== $(date '+%Y-%m-%d %H:%M:%S')  [$reason]  stream=$STREAM ===="
  print -r -- "PROMPT : $PROMPT"
  print -r -- "CTX    : ${ctx:-0}   SID: $sid"
  [[ -n "$context_alert" ]] && print -r -- "ALERT  : $context_alert"
  print -r -- "RESULT : $result"
  print -r -- ""
} >> "$LOG_DIR/agent.log"

# Final output.
if [[ "$STREAM" == "1" ]]; then
  emit RESULT "$result"
elif [[ -n "$context_alert" ]]; then
  print -r -- "$context_alert $result"     # default mode: lead with the heads-up
else
  print -r -- "$result"
fi
