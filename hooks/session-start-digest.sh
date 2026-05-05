#!/bin/bash
# session-start-digest — Layer 2 of read stack.
# Reads SessionStart hook JSON from stdin, queries activity-log for events since
# last seen ULID for this session, outputs Claude Code hookSpecificOutput JSON.
# Silent (zero token cost) when no new events. Always exit 0.

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

LAST_SEEN_FILE="$STATE_DIR/last-seen-$SESSION_ID"
LAST_SEEN=""
[ -f "$LAST_SEEN_FILE" ] && LAST_SEEN=$(/usr/bin/tr -d '[:space:]' < "$LAST_SEEN_FILE" 2>/dev/null || echo "")

# Query: delta since cursor (≤8) + always include P0/P1 from last 7d (priority cap)
QUERY_ARGS=(query --limit 8 --format digest)
[ -n "$LAST_SEEN" ] && QUERY_ARGS+=(--since-ulid "$LAST_SEEN")
DIGEST=$("$BIN" "${QUERY_ARGS[@]}" 2>/dev/null || true)

PRIORITY=$("$BIN" query --priority "P0,P1" --since 7d --limit 5 --format digest 2>/dev/null || true)

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

# Save new last-seen ULID (newest from current digest, querying head row)
NEW_LAST=$("$BIN" query --limit 1 --format ulid 2>/dev/null | /usr/bin/tr -d '[:space:]' || echo "")
[ -n "$NEW_LAST" ] && printf '%s' "$NEW_LAST" > "$LAST_SEEN_FILE" 2>/dev/null

# Emit Claude Code hook JSON
HEADER="recent activity since last session:"
ADDITIONAL=$(printf '%s\n%s' "$HEADER" "$COMBINED" | /usr/bin/jq -Rs '.' 2>/dev/null || echo '""')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ADDITIONAL"
log "emitted session=$SESSION_ID chars=${#COMBINED}"
exit 0
