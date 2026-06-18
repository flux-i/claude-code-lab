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

# --- Orchestration -----------------------------------------------------------
# Every command is first sent to a small ROUTER llm that decides, for THIS command:
# which model + reasoning effort the worker should use, and whether to resume the
# existing conversation or start fresh. It honors explicit directives in the command
# ("use opus", "xhigh reasoning", "quick answer", …) and otherwise picks sensibly.
# The router runs on sonnet/medium (it's just a fast classifier); ordinary tasks
# default to sonnet/high, with opus/xhigh reserved for hard work or when asked. The
# "new conversation" command and the HARD_MAX_CTX cap remain deterministic overrides
# regardless of what the router says.
ORCH_MODEL="${VOICE_ORCH_MODEL:-sonnet}"    # the router/orchestrator model (fast classifier)
ORCH_EFFORT="${VOICE_ORCH_EFFORT:-medium}"  # the router/orchestrator reasoning effort
DEF_MODEL="${VOICE_DEFAULT_MODEL:-sonnet}"  # worker fallback if routing fails/disabled
DEF_EFFORT="${VOICE_DEFAULT_EFFORT:-high}"  # worker effort fallback
ROUTE_ENABLED="${VOICE_ROUTER:-1}"          # set 0 to bypass the router (falls back to ctx/age heuristic + defaults)

emit() {                                  # one protocol line (real tab delimiter)
  # The protocol is one line per message, so a newline in the text would split it
  # across stdout lines — the continuation lines have no TAG and get dropped (this
  # silently truncated multi-line replies, e.g. poems). Flatten newlines to spaces.
  local text=${2//$'\n'/ }; text=${text//$'\r'/ }
  print -r -- "$1"$'\t'"$text"
  [[ "$STREAM" == "1" ]] && print -r -- "$(date '+%H:%M:%S')  $1  $text" >> "$LOG_DIR/protocol.log"
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
sid=""
last=0
age=0
prev_ctx=0
alerted=0
forced_reset=0
TASK="$PROMPT"              # worker prompt — the router may strip a model/effort directive from it
WMODEL="$DEF_MODEL"         # worker model  (router decides; falls back to default)
WEFFORT="$DEF_EFFORT"       # worker effort (router decides; falls back to default)
route_mode=""              # "resume" | "new" from the router (guardrails can still override)
route_reason=""

# Load prior session facts. The resume/new decision itself is made below (router + guardrails).
if [[ -f "$STATE" ]]; then
  sid=$(jq -r '.session_id // empty' "$STATE" 2>/dev/null)
  last=$(jq -r '.last_used // 0'     "$STATE" 2>/dev/null)
  ctx=$(jq -r '.context_tokens // 0' "$STATE" 2>/dev/null)
  alerted=$(jq -r '.alerted // 0'    "$STATE" 2>/dev/null)
  prev_ctx=${ctx:-0}
  age=$(( now - ${last:-0} ))
  (( prev_ctx >= HARD_MAX_CTX )) && forced_reset=1
fi

# A "usable" session is one we could legitimately resume (exists and under the hard cap).
session_exists=0
[[ -n "$sid" ]] && (( prev_ctx < HARD_MAX_CTX )) && session_exists=1

# ---- Router: pick the worker's model + effort + resume/new for THIS command -------
# One fast ephemeral sonnet/medium call. Honors explicit directives in the command and
# otherwise chooses sensibly; replies with a single minified JSON object. --no-session-
# persistence keeps it from creating a resumable session of its own.
if [[ "$ROUTE_ENABLED" == "1" ]]; then
  ROUTER_SYS='You are the dispatcher for a push-to-talk voice assistant backed by Claude Code. Read the spoken COMMAND (and the SESSION line) and decide how to run it. Output ONLY one minified JSON object — no prose, no markdown, no code fences. Do NOT use tools and do NOT perform the task.

MODELS (capability / speed / cost per 1M tokens in/out):
- haiku  = Claude Haiku 4.5 — fastest, cheapest ($1/$5), 200K context. Best for trivial or quick commands, simple lookups, short confirmations. Does NOT support a reasoning effort.
- sonnet = Claude Sonnet 4.6 — balanced speed + intelligence ($3/$15), 1M context. The everyday default: ordinary commands, explanations, light coding. Effort low–high.
- opus   = Claude Opus 4.8 — most capable, slowest, priciest ($5/$25), 1M context. Use for hard coding, debugging, multi-step reasoning, architecture, or long autonomous work. Effort low–xhigh.

EFFORT (reasoning depth vs latency — ignored for haiku, which has none):
- low    = fastest, shallowest; simple well-scoped or latency-sensitive work
- medium = balanced
- high   = deeper reasoning; the right minimum for most real work
- xhigh  = deepest and slowest; only the hardest coding/agentic tasks. OPUS ONLY — never pair xhigh with sonnet or haiku.

Output keys:
"model": "opus" | "sonnet" | "haiku"
"effort": "low" | "medium" | "high" | "xhigh"
"mode": "resume" | "new"
"prompt": the task to run, with any instruction about WHICH model or effort to use removed
"reason": at most 8 words

Rules:
- If the COMMAND explicitly names a model and/or a reasoning level (e.g. "use opus", "with sonnet", "xhigh"/"max reasoning"/"think hard", "quick"/"low effort"), honor it EXACTLY and strip that phrase from "prompt".
- Otherwise choose by difficulty: trivial/quick -> haiku; ordinary requests -> sonnet/high; hard coding, debugging, multi-step reasoning, or architecture -> opus/high (opus/xhigh only if genuinely hard).
- Keep effort valid for the model: never xhigh unless model is opus.
- mode: prefer "resume" when the COMMAND continues the current topic or a recent session exists; choose "new" for a clearly different topic or when no usable session exists.'

  router_input="COMMAND: $PROMPT
SESSION: exists=$session_exists age_seconds=$age context_tokens=$prev_ctx"

  # Pure classifier: --system-prompt REPLACES Claude Code's large default prompt
  # (not --append-, which keeps it), and an empty --allowed-tools means no tools are
  # loaded. Keeps the router small/fast and stops it from ever trying to DO the task.
  router_raw=$("$CLAUDE" -p "$router_input" \
        --model "$ORCH_MODEL" --effort "$ORCH_EFFORT" \
        --system-prompt "$ROUTER_SYS" \
        --allowed-tools '' \
        --no-session-persistence \
        --dangerously-skip-permissions 2>>"$LOG_DIR/agent.err")
  router_json=${router_raw//'```json'/}; router_json=${router_json//'```'/}   # strip any code fences
  if print -r -- "$router_json" | jq -e . >/dev/null 2>&1; then
    m=$(print -r --  "$router_json" | jq -r '.model  // empty')
    e=$(print -r --  "$router_json" | jq -r '.effort // empty')
    md=$(print -r -- "$router_json" | jq -r '.mode   // empty')
    pr=$(print -r -- "$router_json" | jq -r '.prompt // empty')
    rr=$(print -r -- "$router_json" | jq -r '.reason // empty')
    [[ "$m"  == (opus|sonnet|haiku) ]]     && WMODEL="$m"
    [[ "$e"  == (low|medium|high|xhigh) ]] && WEFFORT="$e"
    [[ "$md" == (resume|new) ]]            && route_mode="$md"
    [[ -n "$pr" ]]                          && TASK="$pr"
    route_reason="$rr"
  fi
fi

# Keep the worker's model+effort combo valid (the CLI 400s otherwise): haiku takes no
# effort, and xhigh is opus-only. The router is told this too; this is the safety net.
[[ "$WMODEL" == haiku* ]] && WEFFORT=""
[[ "$WEFFORT" == "xhigh" && "$WMODEL" != opus* ]] && WEFFORT="high"
WORKER_FLAGS=(--model "$WMODEL")
[[ -n "$WEFFORT" ]] && WORKER_FLAGS+=(--effort "$WEFFORT")

# ---- Resume/new decision: the router is advisory; these guardrails win -------------
if (( forced_reset == 1 )) || [[ -z "$sid" ]]; then
  route_mode="new"                       # hard cap hit, or no prior session → must be fresh
elif [[ -z "$route_mode" ]]; then        # router disabled/unparseable → fall back to ctx/age heuristic
  if (( session_exists == 1 )) && (( age < MAX_AGE || prev_ctx <= OLD_OK_CTX )); then
    route_mode="resume"
  else
    route_mode="new"
  fi
fi

if [[ "$route_mode" == "resume" && "$session_exists" == "1" ]]; then
  resume=(--resume "$sid")
  reason="resume (router; age=${age}s ctx=${prev_ctx}; $WMODEL/$WEFFORT)"
else
  resume=()
  reason="new (${route_reason:-heuristic}; $WMODEL/$WEFFORT)"
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
    # Collapse newlines so a multi-line answer (e.g. a poem) stays a single protocol
    # line — the read loop below is line-based and would otherwise lose every line
    # after the first. Mirrors the SAY branch above.
    ("SID\t" + (.session_id // "")), ("RESULT\t" + ((.result // "") | gsub("\n";" ")))
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
  done < <( "$CLAUDE" -p "$TASK" "$@" "${WORKER_FLAGS[@]}" \
              --output-format stream-json --verbose \
              --append-system-prompt "$SYS" \
              --dangerously-skip-permissions 2>>"$LOG_DIR/agent.err" \
            | jq -rc --unbuffered "$JQ_PROTO" )
}

run_json() {  # default: block, capture full json, extract result (live-app contract)
  local out
  out=$("$CLAUDE" -p "$TASK" "$@" "${WORKER_FLAGS[@]}" \
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
  print -r -- "ROUTER : model=$WMODEL effort=${WEFFORT:-none} mode=$route_mode  (${route_reason:-—})"
  [[ "$TASK" != "$PROMPT" ]] && print -r -- "TASK   : $TASK"
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
