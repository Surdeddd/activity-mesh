#!/bin/bash

# shellcheck shell=bash

set -uo pipefail

: "${ACTIVITY_MESH_SYNC:=$HOME/Sync/activity}"
: "${ACTIVITY_MESH_STATE:=$HOME/.local/state/activity-mesh}"
: "${ACTIVITY_MESH_HOME:=$HOME/.local/share/activity-mesh}"
: "${ACTIVITY_MESH_LOG:=$HOME/.local/state/activity-mesh}"
mkdir -p "$ACTIVITY_MESH_STATE" "$ACTIVITY_MESH_LOG" 2>/dev/null || true

am_host() {
    case "$(uname -s)" in
        Darwin) hostname 2>/dev/null || echo unknown ;;
        Linux)  hostname 2>/dev/null || echo linux ;;
        *)      echo unknown ;;
    esac
}

am_now_ms() {
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s%3N
    else
        local probe; probe=$(date +%s%3N 2>/dev/null)
        case "$probe" in
            *N|*[!0-9]*) ;;
            ?*)         echo "$probe"; return ;;
        esac
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import time;print(int(time.time()*1000))'
        else
            echo "$(date +%s)000"
        fi
    fi
}

am_emit() {
    local name="$1" tier="$2" status="$3" message="$4"
    local end dur
    end=$(am_now_ms)
    dur=$(( end - CHECK_START_MS ))
    [ "$dur" -lt 0 ] && dur=0
    printf '{"name":"%s","tier":%d,"status":"%s","message":%s,"duration_ms":%d}\n' \
        "$name" "$tier" "$status" \
        "$(printf '%s' "$message" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')" \
        "$dur"
}

am_start() { CHECK_START_MS=$(am_now_ms); export CHECK_START_MS; }

am_human_bytes() {
    local b="$1"
    if   [ "$b" -gt 1073741824 ]; then printf '%.1fG' "$(echo "scale=1;$b/1073741824" | bc)"
    elif [ "$b" -gt 1048576 ];    then printf '%.1fM' "$(echo "scale=1;$b/1048576" | bc)"
    elif [ "$b" -gt 1024 ];       then printf '%.1fK' "$(echo "scale=1;$b/1024" | bc)"
    else printf '%dB' "$b"
    fi
}

am_notify_telegram() {
    local msg="$1" token="${TELEGRAM_BOT_TOKEN:-}" chat="${TELEGRAM_CHAT_ID:-}" envf resp
    envf="${TELEGRAM_ENV:-$HOME/.config/activity-mesh/telegram.env}"
    if [ -z "$token" ] && [ -f "$envf" ]; then
        token=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi
    if [ -z "$chat" ] && [ -f "$envf" ]; then
        chat=$(grep -E '^TELEGRAM_CHAT_ID=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi
    { [ -n "$token" ] && [ -n "$chat" ] && command -v curl >/dev/null 2>&1; } || return 1
    resp=$(curl -s -m 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=${msg}" 2>/dev/null) || return 1
    printf '%s' "$resp" | grep -q '"ok":true'
}

am_notify() {
    local msg="$1"
    if [ -n "${ACTIVITY_MESH_NOTIFY_CMD:-}" ]; then
        # shellcheck disable=SC2086
        printf '%s' "$msg" | ${ACTIVITY_MESH_NOTIFY_CMD} 2>/dev/null && return 0
    fi
    local legacy=""
    if command -v notify-maxim >/dev/null 2>&1; then legacy="notify-maxim"
    elif [ -x "$HOME/.local/bin/notify-maxim" ]; then legacy="$HOME/.local/bin/notify-maxim"
    fi
    if [ -n "$legacy" ]; then
        printf '%s' "$msg" | "$legacy" 2>/dev/null && return 0
    fi
    am_notify_telegram "$msg"
}
