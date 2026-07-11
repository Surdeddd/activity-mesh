#!/bin/bash
set -uo pipefail

STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
CONFIG_DIR="${ACTIVITY_MESH_CONFIG:-$HOME/.config/activity-mesh}"
LOG="$STATE_DIR/user-prompt-router.log"
INJ_LOG="$STATE_DIR/injections.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null); [ -z "$INPUT" ] && exit 0

JQ="${ACTIVITY_MESH_JQ:-$(command -v jq 2>/dev/null || true)}"
if [ -z "$JQ" ]; then
    for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do
        [ -x "$c" ] && { JQ="$c"; break; }
    done
fi
[ -z "$JQ" ] && { log "skip: no jq available"; exit 0; }

SEP=$'\001'
JQ_OUT=$(printf '%s' "$INPUT" | "$JQ" -j --arg sep "$SEP" '(.prompt // "") + $sep + (.session_id // "unknown")' 2>/dev/null || true)
PROMPT="${JQ_OUT%%"${SEP}"*}"
SESSION_ID="${JQ_OUT##*"${SEP}"}"
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
[ -z "$PROMPT" ] && exit 0

TOKENS_FILE="$STATE_DIR/tokens-$SESSION_ID"
/usr/bin/find "$STATE_DIR" -name 'tokens-*' -mtime +1 -delete 2>/dev/null || true
TOKENS_USED=0
[ -f "$TOKENS_FILE" ] && { read -r TOKENS_USED < "$TOKENS_FILE" || TOKENS_USED=0; }
case "$TOKENS_USED" in ''|*[!0-9]*) TOKENS_USED=0 ;; esac
[ "$TOKENS_USED" -gt 2000 ] && { log "session=$SESSION_ID over budget, silent"; exit 0; }

if command -v python3 >/dev/null 2>&1; then
    LOWER=$(printf '%s' "$PROMPT" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().lower())' 2>/dev/null)
else
    LOWER=$(printf '%s' "$PROMPT" | LC_ALL=en_US.UTF-8 /usr/bin/tr '[:upper:]' '[:lower:]')
fi

ANTI_RE='что такое|как сделать|как (написать|создать)|напиши|создай|сделай мне|what is|how (do|to|can)|write me|generate|create a'
[[ "$LOWER" =~ $ANTI_RE ]] && { log "anti-trigger session=$SESSION_ID"; exit 0; }

TEMPORAL_RE='что (было|делал[аи]?|произошло|сделал[аи]?)|сегодня|вчера|за день|за неделю|recent|today|yesterday|this week|last (hour|day|week)'
STATUS_RE='статус|чё там|что (в работе|пендинг|пендингует)|status|pending|active task|what.?s going on|what.?s up'
INCIDENT_RE='incident|авария|падал|сломал|упал|crashed|failed|broken|outage'

INTENT=""; SCOPE_FILTER=""; AGENT_FILTER=""
if   [[ "$LOWER" =~ $INCIDENT_RE ]]; then INTENT="incident"
elif [[ "$LOWER" =~ $TEMPORAL_RE ]]; then INTENT="temporal"
elif [[ "$LOWER" =~ $STATUS_RE   ]]; then INTENT="status"
fi

SCOPES_CACHE="$CONFIG_DIR/scopes-cache"
if [ -f "$SCOPES_CACHE" ]; then
    while IFS= read -r scope; do
        [ -z "$scope" ] && continue
        case "$LOWER" in *"$scope"*) SCOPE_FILTER="$scope"; [ -z "$INTENT" ] && INTENT="scope"; break ;; esac
    done < "$SCOPES_CACHE"
fi

AGENTS_CACHE="$CONFIG_DIR/agents-cache"
if [ -f "$AGENTS_CACHE" ]; then
    WEAK_AGENT=""
    while IFS=$'\t' read -r aid strong weak; do
        [ -z "$aid" ] && continue
        if [ -z "$AGENT_FILTER" ] && [ -n "$strong" ]; then
            IFS=',' read -r -a ALIASES <<< "$strong"
            for al in "${ALIASES[@]}"; do
                [ -z "$al" ] && continue
                case "$LOWER" in *"$al"*) AGENT_FILTER="$aid"; break ;; esac
            done
        fi
        if [ -z "$WEAK_AGENT" ] && [ -n "$weak" ]; then
            IFS=',' read -r -a WALIASES <<< "$weak"
            for al in "${WALIASES[@]}"; do
                [ -z "$al" ] && continue
                case "$LOWER" in *"$al"*) WEAK_AGENT="$aid"; break ;; esac
            done
        fi
    done < "$AGENTS_CACHE"
    if [ -n "$AGENT_FILTER" ]; then
        [ -z "$INTENT" ] && INTENT="agent"
    elif [ -n "$WEAK_AGENT" ]; then
        AGENT_FILTER="$WEAK_AGENT"
    fi
fi
[ -z "$INTENT" ] && exit 0

BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then log "skip intent=$INTENT: no binary"; exit 0; fi

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

MAX_CHARS=2000
[ "${#RESULT}" -gt "$MAX_CHARS" ] && RESULT=$(printf '%s\n' "$RESULT" | /usr/bin/head -n 8)
[ "${#RESULT}" -gt "$MAX_CHARS" ] && RESULT="${RESULT:0:$MAX_CHARS}…[truncated]"

FIRE_TOKENS=$(( ${#RESULT} / 4 ))
NEW_TOKENS=$(( TOKENS_USED + FIRE_TOKENS ))
echo "$NEW_TOKENS" > "$TOKENS_FILE" 2>/dev/null
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $SESSION_ID $FIRE_TOKENS" >> "$INJ_LOG" 2>/dev/null || true
if [ "$(wc -c < "$INJ_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    /usr/bin/tail -n 2000 "$INJ_LOG" > "$INJ_LOG.tmp" 2>/dev/null && /bin/mv -f "$INJ_LOG.tmp" "$INJ_LOG" 2>/dev/null || true
fi

CTX=$(printf 'activity-mesh (%s match):\n%s' "$INTENT" "$RESULT" | "$JQ" -Rs '.' 2>/dev/null || echo '""')
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$CTX"
log "emitted intent=$INTENT session=$SESSION_ID chars=${#RESULT} fire_tokens=$FIRE_TOKENS budget=$NEW_TOKENS"
exit 0
