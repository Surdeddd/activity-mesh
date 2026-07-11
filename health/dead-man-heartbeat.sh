#!/bin/bash

set -uo pipefail

DAEMON_URL="${ACTIVITY_MESH_HEALTH_URL:-http://127.0.0.1:7459/health}"
STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
MISS_FILE="$STATE_DIR/heartbeat-misses"
LAST_ALERT_FILE="$STATE_DIR/heartbeat-last-alert"
LOG="$STATE_DIR/heartbeat.log"
THRESHOLD="${HEARTBEAT_THRESHOLD:-3}"
ALERT_COOLDOWN="${HEARTBEAT_COOLDOWN:-3600}"     # don't spam more than 1×/hour

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

read_int() {
    [ -f "$1" ] || { echo 0; return; }
    v=$(/usr/bin/tr -d '[:space:]' < "$1" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

ok=0
if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$DAEMON_URL" 2>/dev/null || echo 000)
    case "$code" in 200|204) ok=1 ;; esac
fi

find_activity_log() {
    local bin
    for bin in \
        "$HOME/.local/bin/activity-log" \
        "/usr/local/bin/activity-log" \
        "$HOME/Projects/activity-mesh/bin/activity-log-darwin-arm64" \
        "$HOME/Projects/Personal/activity-mesh/bin/activity-log-darwin-arm64" \
        "$(command -v activity-log 2>/dev/null)"; do
        [ -n "$bin" ] && [ -x "$bin" ] || continue
        echo "$bin"
        return 0
    done
    return 1
}
AL_BIN=$(find_activity_log) || AL_BIN=""

emit_canary() {
    [ -n "$AL_BIN" ] || return 0
    "$AL_BIN" emit \
        --kind canary \
        --scope activity-mesh \
        --agent heartbeat \
        --summary "hourly heartbeat $(date -u +%FT%TZ) ok=$1" \
        >/dev/null 2>&1
    return 0
}
emit_canary "$ok" || true

if [ -n "$AL_BIN" ]; then
    "$AL_BIN" clock-sync >/dev/null 2>&1 || log "clock-sync failed (offset cache stale)"
fi

if [ -n "$AL_BIN" ]; then
    "$AL_BIN" refresh-scopes >/dev/null 2>&1 || log "refresh-scopes failed (scopes-cache stale)"
fi

prev=$(read_int "$MISS_FILE")
if [ "$ok" -eq 1 ]; then
    echo 0 > "$MISS_FILE" 2>/dev/null
    log "ok url=$DAEMON_URL prev_misses=$prev"
    exit 0
fi
misses=$(( prev + 1 ))
echo "$misses" > "$MISS_FILE" 2>/dev/null
log "miss url=$DAEMON_URL misses=$misses code=${code:-?}"

if [ "$misses" -lt "$THRESHOLD" ]; then exit 0; fi

last=$(read_int "$LAST_ALERT_FILE"); now=$(date +%s)
if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "$ALERT_COOLDOWN" ]; then
    log "alert suppressed (cooldown $(( now - last ))s < $ALERT_COOLDOWN)"
    exit 0
fi

HERE_DMH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE_DMH/lib.sh"

host=$(hostname -s 2>/dev/null || echo unknown)
ts_iso=$(date -u +%FT%TZ)
TEXT="🚨 *activity-mesh daemon down* · CRITICAL / КРИТИЧНО

Daemon not responding to /health for $misses consecutive checks — operational history is being lost.

📊 Details:
• host: $host
• url: $DAEMON_URL
• misses: $misses in a row (threshold $THRESHOLD)
• runbook: RB-6 launchd-stuck

⚡ Action: revive daemon
\`launchctl list | grep activity-mesh\`
\`launchctl kickstart -k gui/\$UID/com.activity-mesh.daemon\`
log: \`$LOG\`

━━━━━━━━━━━━━━━━━

🇷🇺 Демон не отвечает на /health подряд $misses раз — operational history теряется.

📊 Детали:
• host: $host
• url: $DAEMON_URL
• misses: $misses подряд (threshold $THRESHOLD)
• runbook: RB-6 launchd-stuck

⚡ Действие: revive daemon
\`launchctl list | grep activity-mesh\`
\`launchctl kickstart -k gui/\$UID/com.activity-mesh.daemon\`
log: \`$LOG\`

\`$ts_iso · $host\`"

if am_notify "$TEXT"; then
    log "alert sent"
    echo "$now" > "$LAST_ALERT_FILE" 2>/dev/null
else
    log "alert FAILED (no notify cmd / no telegram creds / curl missing)"
fi

exit 0
