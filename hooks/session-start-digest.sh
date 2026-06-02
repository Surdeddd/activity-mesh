#!/bin/bash
# session-start-digest — Layer 2 of read stack.
# Reads SessionStart hook JSON from stdin, queries activity-log for recent
# events, outputs Claude Code hookSpecificOutput JSON.
# Silent (zero token cost) when no events. Always exit 0.

set -uo pipefail

STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
LOG="$STATE_DIR/session-start.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null); [ -z "$INPUT" ] && INPUT='{}'
SESSION_ID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

# Resolve activity-log binary (graceful degrade if missing — P2 not yet shipped)
BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    log "skip session=$SESSION_ID: activity-log binary not found"
    exit 0
fi

# Recent activity window. The current activity-log CLI has no ULID cursor
# (--since-ulid) and --since accepts only durations, not absolute times — so a
# 24h window is the closest proxy for "since last session".
DIGEST=$("$BIN" query --since 24h --limit 8 --format text 2>/dev/null || true)

# Incidents: error events are rare, so widen to 30d (matches user-prompt-router).
PRIORITY=$("$BIN" query --kind error --since 30d --limit 5 --format text 2>/dev/null || true)

# Combine; if both empty, silent exit
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

# Token cap ≤250 (1 token ≈ 4 chars conservative → 1000 char cap)
MAX_CHARS=1000
if [ "${#COMBINED}" -gt "$MAX_CHARS" ]; then
    COMBINED="$(printf '%s' "$COMBINED" | /usr/bin/cut -c 1-"$MAX_CHARS")…[truncated]"
fi

# Emit Claude Code hook JSON
HEADER="recent activity since last session:"
ADDITIONAL=$(printf '%s\n%s' "$HEADER" "$COMBINED" | /usr/bin/jq -Rs '.' 2>/dev/null || echo '""')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ADDITIONAL"
log "emitted session=$SESSION_ID chars=${#COMBINED}"
exit 0
