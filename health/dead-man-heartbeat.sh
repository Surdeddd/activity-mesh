#!/bin/bash
# dead-man-heartbeat.sh — INDEPENDENT process. NOT the same daemon it's checking.
#
# Behavior:
#   - GET http://localhost:7459/health (5s timeout)
#   - On miss, increment $STATE/heartbeat-misses (a single integer)
#   - On hit,  reset miss count to 0
#   - When misses ≥ 3 → tier-4 alert via DIRECT curl to Telegram bot API
#     (NO dependency on activity-mesh daemon — that's the whole point)
#
# Always exit 0 (cron/launchd unfriendly otherwise).

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

# 1. try health probe — 5s budget
ok=0
if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$DAEMON_URL" 2>/dev/null || echo 000)
    case "$code" in 200|204) ok=1 ;; esac
fi

# find the first available activity-log binary (shared by canary + clock-sync).
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

# emit hourly canary event into the shard so the canary health-check sees life.
# Independent of daemon-alive status — emits regardless. Picks first available
# binary; silent fail if none. Bounded to <2s by command-budget chain.
emit_canary() {
    [ -n "$AL_BIN" ] || return 0
    "$AL_BIN" emit \
        --kind canary \
        --scope infra:heartbeat \
        --agent heartbeat \
        --summary "hourly heartbeat $(date -u +%FT%TZ) ok=$1" \
        >/dev/null 2>&1
    return 0
}
emit_canary "$ok" || true

# refresh the cached NTP clock offset hourly (feeds clock_offset_ms on every
# emitted event). Best-effort: the subcommand has its own 3s SNTP timeout and
# leaves the previous cache untouched on failure — never blocks the heartbeat.
if [ -n "$AL_BIN" ]; then
    "$AL_BIN" clock-sync >/dev/null 2>&1 || log "clock-sync failed (offset cache stale)"
fi

# regenerate the L3 router scopes-cache from the scopes registry hourly
# (active scopes minus router:false). Best-effort: on registry read/parse
# failure the subcommand exits non-zero and leaves the existing cache
# untouched — never blocks the heartbeat.
if [ -n "$AL_BIN" ]; then
    "$AL_BIN" refresh-scopes >/dev/null 2>&1 || log "refresh-scopes failed (scopes-cache stale)"
fi

# 2. update miss counter
prev=$(read_int "$MISS_FILE")
if [ "$ok" -eq 1 ]; then
    echo 0 > "$MISS_FILE" 2>/dev/null
    log "ok url=$DAEMON_URL prev_misses=$prev"
    exit 0
fi
misses=$(( prev + 1 ))
echo "$misses" > "$MISS_FILE" 2>/dev/null
log "miss url=$DAEMON_URL misses=$misses code=${code:-?}"

# 3. trigger alert if threshold hit
if [ "$misses" -lt "$THRESHOLD" ]; then exit 0; fi

# cooldown
last=$(read_int "$LAST_ALERT_FILE"); now=$(date +%s)
if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "$ALERT_COOLDOWN" ]; then
    log "alert suppressed (cooldown $(( now - last ))s < $ALERT_COOLDOWN)"
    exit 0
fi

# 4. INDEPENDENT alert path: read token from telegram channel .env, curl to bot api
TG_ENV="${TELEGRAM_ENV:-$HOME/.claude/channels/telegram/.env}"
TOKEN=""
if [ -f "$TG_ENV" ]; then
    TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
CHAT_ID="${TELEGRAM_CHAT_ID:-466332453}"   # Maxim's user_id default

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
\`launchctl kickstart -k gui/\$UID/com.maxim.activity-mesh.daemon\`
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
\`launchctl kickstart -k gui/\$UID/com.maxim.activity-mesh.daemon\`
log: \`$LOG\`

\`$ts_iso · $host\`"

if [ -n "$TOKEN" ] && command -v curl >/dev/null 2>&1; then
    resp=$(curl -s -m 10 -X POST \
        "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${TEXT}" 2>/dev/null) || resp=""
    if printf '%s' "$resp" | grep -q '"ok":true'; then
        log "alert sent to chat_id=${CHAT_ID}"
        echo "$now" > "$LAST_ALERT_FILE" 2>/dev/null
    else
        log "alert FAILED resp=${resp:0:200}"
    fi
else
    log "no token / curl: cannot send alert"
fi

exit 0
