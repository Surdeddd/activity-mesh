#!/bin/bash

set -uo pipefail

DAEMON_URL="${ACTIVITY_MESH_HEALTH_URL:-http://127.0.0.1:7459/health}"
STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
MISS_FILE="$STATE_DIR/heartbeat-misses"
LAST_ALERT_FILE="$STATE_DIR/heartbeat-last-alert"
LOG="$STATE_DIR/heartbeat.log"
THRESHOLD="${HEARTBEAT_THRESHOLD:-3}"
ALERT_COOLDOWN="${HEARTBEAT_COOLDOWN:-3600}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

read_int() {
    [ -f "$1" ] || { echo 0; return; }
    v=$(/usr/bin/tr -d '[:space:]' < "$1" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

ok=0
why=""
if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -m "${CANARY_TIMEOUT:-15}" -w '%{http_code}' "$DAEMON_URL" 2>/dev/null)
    rc=$?
    case "$code" in
        200|204) ok=1 ;;
        *)
            case "$rc" in
                7)  why="connect-refused" ;;
                28) why="timeout" ;;
                52) why="empty-reply" ;;
                *)  why="curl-rc-$rc" ;;
            esac
            ;;
    esac
    [ -z "$code" ] && code=000
fi

loadavg=$(/usr/bin/uptime 2>/dev/null | /usr/bin/awk -F'averages?:' '{print $2}' | /usr/bin/awk '{gsub(/,/,"."); print $1}')
case "$loadavg" in ''|*[!0-9.]*) loadavg="?" ;; esac

BUSY_LOAD="${CANARY_BUSY_LOAD:-12}"
inconclusive=0
if [ "$ok" -eq 0 ] && { [ "$why" = "timeout" ] || [ "$why" = "empty-reply" ]; } && [ "$loadavg" != "?" ]; then
    if [ "$(printf '%s\n%s\n' "$loadavg" "$BUSY_LOAD" | /usr/bin/sort -g | /usr/bin/tail -1)" = "$loadavg" ]; then
        inconclusive=1
    fi
fi

find_activity_log() {
    local bin
    for bin in \
        "${ACTIVITY_MESH_BIN:-}" \
        "$HOME/.local/bin/activity-log" \
        "/usr/local/bin/activity-log" \
        "/opt/homebrew/bin/activity-log" \
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
    local summary
    summary="hourly heartbeat $(date -u +%FT%TZ) ok=$ok"
    [ "$ok" -eq 1 ] || summary="$summary why=${why:-unknown} busy=$inconclusive"
    "$AL_BIN" emit \
        --kind canary \
        --scope activity-mesh \
        --agent heartbeat \
        --summary "$summary" \
        >/dev/null 2>&1
    return 0
}
emit_canary || true

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
if [ "$inconclusive" -eq 1 ]; then
    log "inconclusive url=$DAEMON_URL why=$why load=$loadavg (>$BUSY_LOAD) — счётчик не трогаю, misses=$prev"
    exit 0
fi

misses=$(( prev + 1 ))
echo "$misses" > "$MISS_FILE" 2>/dev/null
log "miss url=$DAEMON_URL misses=$misses code=${code:-?} why=${why:-?} load=$loadavg"

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
uid=$(id -u 2>/dev/null || echo 501)
TEXT_EN="🚨 activity-mesh: the daemon is down

The daemon did not answer /health $misses times in a row: the index and the HTTP API (/search, /recent, /push) are unavailable. CLI writes to the shards are not affected.

📊 Details
• host: $host
• url: $DAEMON_URL
• misses in a row: $misses (threshold $THRESHOLD)
• last cause: ${why:-?} (curl code ${code:-?}), load $loadavg
• runbook: RB-6 launchd-stuck

⚡ What to do
• launchctl list | grep activity-mesh
• launchctl kickstart -k gui/$uid/com.activity-mesh.daemon
• log: $LOG"
TEXT_RU="🚨 activity-mesh: демон не отвечает

Демон не ответил на /health $misses раз подряд: индекс и HTTP API (/search, /recent, /push) недоступны. Запись событий через CLI не затронута.

📊 Детали
• хост: $host
• адрес: $DAEMON_URL
• промахов подряд: $misses (порог $THRESHOLD)
• последняя причина: ${why:-?} (код curl ${code:-?}), нагрузка $loadavg
• runbook: RB-6 launchd-stuck

⚡ Что сделать
• launchctl list | grep activity-mesh
• launchctl kickstart -k gui/$uid/com.activity-mesh.daemon
• лог: $LOG"

if am_notify "$(am_t "$TEXT_EN" "$TEXT_RU")" fail; then
    log "alert sent"
    echo "$now" > "$LAST_ALERT_FILE" 2>/dev/null
    am_record_alert heartbeat fail
else
    log "alert FAILED (no notify cmd / no telegram creds / curl missing)"
fi

exit 0
