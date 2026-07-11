#!/bin/bash

set -uo pipefail

STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
LOG="$STATE_DIR/session-start.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null); [ -z "$INPUT" ] && INPUT='{}'
JQ="${ACTIVITY_MESH_JQ:-$(command -v jq 2>/dev/null || true)}"
if [ -z "$JQ" ]; then
    for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do
        [ -x "$c" ] && { JQ="$c"; break; }
    done
fi
[ -z "$JQ" ] && exit 0
SESSION_ID=$(echo "$INPUT" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    log "skip session=$SESSION_ID: activity-log binary not found"
    exit 0
fi

DIGEST=$("$BIN" query --since 24h --exclude-kind canary,heartbeat --limit 8 --format text 2>/dev/null || true)

PRIORITY=$("$BIN" query --kind error --since 30d --limit 5 --format text 2>/dev/null || true)

COMBINED=""
if [ -n "$DIGEST" ]; then COMBINED="$DIGEST"; fi
if [ -n "$PRIORITY" ]; then
    if [ -n "$COMBINED" ]; then COMBINED="$COMBINED"$'\n'"---"$'\n'"$PRIORITY"
    else COMBINED="$PRIORITY"; fi
fi

if [ -z "$COMBINED" ]; then
    log "silent session=$SESSION_ID: no events"
    exit 0
fi

MAX_CHARS=1000
if [ "${#COMBINED}" -gt "$MAX_CHARS" ]; then
    COMBINED="${COMBINED:0:$MAX_CHARS}…[truncated]"
fi

HEADER="recent activity since last session:"
ADDITIONAL=$(printf '%s\n%s' "$HEADER" "$COMBINED" | "$JQ" -Rs '.' 2>/dev/null || echo '""')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ADDITIONAL"
log "emitted session=$SESSION_ID chars=${#COMBINED}"
exit 0
