#!/bin/bash
# user-prompt-router — Layer 3 invisible breakthrough.
# Detects intent in prompt (RU+EN), shells out to activity-log for scoped slice,
# emits hookSpecificOutput JSON. Silent (zero tokens) on no-match. Exit 0 always.
set -uo pipefail

STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
CONFIG_DIR="${ACTIVITY_MESH_CONFIG:-$HOME/.config/activity-mesh}"
LOG="$STATE_DIR/user-prompt-router.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null); [ -z "$INPUT" ] && exit 0

# Single jq fork extracts both fields with sentinel separator
SEP=$'\001'
JQ_OUT=$(printf '%s' "$INPUT" | /usr/bin/jq -j --arg sep "$SEP" '(.prompt // "") + $sep + (.session_id // "unknown")' 2>/dev/null || true)
PROMPT="${JQ_OUT%%"${SEP}"*}"
SESSION_ID="${JQ_OUT##*"${SEP}"}"
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
[ -z "$PROMPT" ] && exit 0

# Per-session token cap — once over budget (>2000), silent for rest of session.
# Lives in STATE_DIR (not /tmp): respects test isolation, survives /tmp purges,
# and stale budgets are reaped instead of accumulating forever.
TOKENS_FILE="$STATE_DIR/tokens-$SESSION_ID"
/usr/bin/find "$STATE_DIR" -name 'tokens-*' -mtime +1 -delete 2>/dev/null || true
TOKENS_USED=0
[ -f "$TOKENS_FILE" ] && { read -r TOKENS_USED < "$TOKENS_FILE" || TOKENS_USED=0; }
case "$TOKENS_USED" in ''|*[!0-9]*) TOKENS_USED=0 ;; esac
[ "$TOKENS_USED" -gt 2000 ] && { log "session=$SESSION_ID over budget, silent"; exit 0; }

# Hooks run with C locale; force UTF-8 or tr leaves Cyrillic uppercase intact
LOWER=$(printf '%s' "$PROMPT" | LC_ALL=en_US.UTF-8 /usr/bin/tr '[:upper:]' '[:lower:]')

# Anti-triggers (definition / how-to / creation — NOT recall)
ANTI_RE='что такое|как сделать|как (написать|создать)|напиши|создай|сделай мне|what is|how (do|to|can)|write me|generate|create a'
[[ "$LOWER" =~ $ANTI_RE ]] && { log "anti-trigger session=$SESSION_ID"; exit 0; }

# Intent regexes (5 categories), bash =~ to avoid grep fork
TEMPORAL_RE='что (было|делал[аи]?|произошло|сделал[аи]?)|сегодня|вчера|за день|за неделю|recent|today|yesterday|this week|last (hour|day|week)'
STATUS_RE='статус|чё там|что (в работе|пендинг|пендингует)|status|pending|active task|what.?s going on|what.?s up'
INCIDENT_RE='incident|авария|падал|сломал|упал|crashed|failed|broken|outage'
AGENT_RE='хермес|виктор|клод-?mac|клод|hermes|viktor|claude-?mac|anton|antоn'

INTENT=""; SCOPE_FILTER=""; AGENT_FILTER=""
if   [[ "$LOWER" =~ $INCIDENT_RE ]]; then INTENT="incident"
elif [[ "$LOWER" =~ $TEMPORAL_RE ]]; then INTENT="temporal"
elif [[ "$LOWER" =~ $STATUS_RE   ]]; then INTENT="status"
fi

# Scope-named (registry-driven). Cache: $CONFIG_DIR/scopes-cache (one per line)
SCOPES_CACHE="$CONFIG_DIR/scopes-cache"
if [ -f "$SCOPES_CACHE" ]; then
    while IFS= read -r scope; do
        [ -z "$scope" ] && continue
        case "$LOWER" in *"$scope"*) SCOPE_FILTER="$scope"; [ -z "$INTENT" ] && INTENT="scope"; break ;; esac
    done < "$SCOPES_CACHE"
fi

# Agent-named with alias normalisation. A bare generic "клод/claude" almost
# always means Claude-the-tool, not the claude-mac agent — it may qualify an
# already-detected intent but never creates one on its own.
if [[ "$LOWER" =~ $AGENT_RE ]]; then
    GENERIC_CLAUDE=0
    case "$LOWER" in
        *хермес*|*hermes*)             AGENT_FILTER="hermes" ;;
        *виктор*|*viktor*)             AGENT_FILTER="viktor" ;;
        *клод-mac*|*claude-mac*)       AGENT_FILTER="claude-mac" ;;
        *клод*|*claude*)               AGENT_FILTER="claude-mac"; GENERIC_CLAUDE=1 ;;
        *anton*|*antоn*)               AGENT_FILTER="anton" ;;
    esac
    [ -z "$INTENT" ] && [ "$GENERIC_CLAUDE" -eq 0 ] && INTENT="agent"
fi
[ -z "$INTENT" ] && exit 0

# Resolve binary (graceful degrade)
BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
# Fallback: launchd/non-interactive shells (e.g. mac-mini agents) often lack
# ~/.local/bin on PATH, so command -v misses the binary that is actually there.
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then log "skip intent=$INTENT: no binary"; exit 0; fi

# Build query args — exactly one --limit per intent
ARGS=(query --format text)
case "$INTENT" in
    temporal) ARGS+=(--since 24h --limit 8) ;;
    status)   ARGS+=(--kind status --since 48h --limit 10) ;;
    incident) ARGS+=(--kind error --since 30d --limit 5) ;;
    scope)    ARGS+=(--scope "$SCOPE_FILTER" --since 30d --limit 15) ;;
    agent)    ARGS+=(--agent "$AGENT_FILTER" --limit 10) ;;
esac
[ -n "$AGENT_FILTER" ] && [ "$INTENT" != "agent" ] && ARGS+=(--agent "$AGENT_FILTER")
[ -n "$SCOPE_FILTER" ] && [ "$INTENT" != "scope" ] && ARGS+=(--scope "$SCOPE_FILTER")

RESULT=$("$BIN" "${ARGS[@]}" 2>/dev/null || true)
[ -z "$RESULT" ] && { log "no events intent=$INTENT"; exit 0; }

# Token cap ≤500 (≈2000 chars). Trim to top 8 lines, then hard-cap the whole
# stream (bash substring — `cut -c` counts per LINE and never capped anything)
MAX_CHARS=2000
[ "${#RESULT}" -gt "$MAX_CHARS" ] && RESULT=$(printf '%s\n' "$RESULT" | /usr/bin/head -n 8)
[ "${#RESULT}" -gt "$MAX_CHARS" ] && RESULT="${RESULT:0:$MAX_CHARS}…[truncated]"

NEW_TOKENS=$(( TOKENS_USED + ${#RESULT} / 4 ))
echo "$NEW_TOKENS" > "$TOKENS_FILE" 2>/dev/null

CTX=$(printf 'activity-mesh (%s match):\n%s' "$INTENT" "$RESULT" | /usr/bin/jq -Rs '.' 2>/dev/null || echo '""')
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$CTX"
log "emitted intent=$INTENT session=$SESSION_ID chars=${#RESULT} budget=$NEW_TOKENS"
exit 0
