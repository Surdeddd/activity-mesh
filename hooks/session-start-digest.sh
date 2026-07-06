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
# jq: PATH first, then the usual absolute homes (macOS 15+ ships /usr/bin/jq).
JQ="${ACTIVITY_MESH_JQ:-$(command -v jq 2>/dev/null || true)}"
if [ -z "$JQ" ]; then
    for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do
        [ -x "$c" ] && { JQ="$c"; break; }
    done
fi
[ -z "$JQ" ] && exit 0
SESSION_ID=$(echo "$INPUT" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

# Resolve activity-log binary (graceful degrade if missing — P2 not yet shipped)
BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
# Fallback: launchd/non-interactive shells often lack ~/.local/bin on PATH.
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    log "skip session=$SESSION_ID: activity-log binary not found"
    exit 0
fi

# Recent activity window. The current activity-log CLI has no ULID cursor
# (--since-ulid) and --since accepts only durations, not absolute times — so a
# 24h window is the closest proxy for "since last session".
# Monitoring noise (canary/heartbeat kinds) is excluded structurally — a
# substring grep also ate real events that merely mentioned "heartbeat".
DIGEST=$("$BIN" query --since 24h --exclude-kind canary,heartbeat --limit 8 --format text 2>/dev/null || true)

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

# Token cap ≤250 (1 token ≈ 4 chars conservative → 1000 char cap).
# Whole-stream bash substring — `cut -c` counts per LINE and never capped
# multi-line digests (observed ~2050 chars slipping through).
MAX_CHARS=1000
if [ "${#COMBINED}" -gt "$MAX_CHARS" ]; then
    COMBINED="${COMBINED:0:$MAX_CHARS}…[truncated]"
fi

# Emit Claude Code hook JSON
HEADER="recent activity since last session:"
ADDITIONAL=$(printf '%s\n%s' "$HEADER" "$COMBINED" | "$JQ" -Rs '.' 2>/dev/null || echo '""')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ADDITIONAL"
log "emitted session=$SESSION_ID chars=${#COMBINED}"
exit 0
