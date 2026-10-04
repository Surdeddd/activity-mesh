#!/bin/bash

# shellcheck shell=bash

set -uo pipefail

: "${ACTIVITY_MESH_SYNC:=$HOME/Sync/activity}"
: "${ACTIVITY_MESH_STATE:=$HOME/.local/state/activity-mesh}"
: "${ACTIVITY_MESH_HOME:=$HOME/.local/share/activity-mesh}"
: "${ACTIVITY_MESH_LOG:=$HOME/.local/state/activity-mesh}"
: "${ACTIVITY_MESH_LANG:=ru}"
mkdir -p "$ACTIVITY_MESH_STATE" "$ACTIVITY_MESH_LOG" 2>/dev/null || true

AM_JQ="${ACTIVITY_MESH_JQ:-}"
if [ -z "$AM_JQ" ]; then
    for _am_c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq "$(command -v jq 2>/dev/null)"; do
        if [ -n "$_am_c" ] && [ -x "$_am_c" ]; then AM_JQ="$_am_c"; break; fi
    done
    unset _am_c
fi

export AM_JQ_DEFS='def ev_ts:
    (if type == "object" then .ts else null end)
    | if type == "string" then
        (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<z>Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])$") // null)
        | if . == null then 0
          else
            . as $m
            | (try (($m.d + "Z") | fromdateiso8601) catch null) as $t
            | if $t == null then 0
              elif $m.z == "Z" then $t
              else
                ($m.z | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")) as $o
                | (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60) as $off
                | if $o.s == "+" then $t - $off else $t + $off end
              end
          end
      else 0 end;
'

am_t() {
    case "$ACTIVITY_MESH_LANG" in
        en*) printf '%s' "$1" ;;
        *)   printf '%s' "$2" ;;
    esac
}

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
        return
    fi
    local probe; probe=$(date +%s%3N 2>/dev/null)
    case "$probe" in
        ''|*N|*[!0-9]*) ;;
        *) echo "$probe"; return ;;
    esac
    if [ -n "$AM_JQ" ]; then
        "$AM_JQ" -n 'now * 1000 | floor'
    else
        echo "$(date +%s)000"
    fi
}

am_last_wake() {
    if [ -n "${ACTIVITY_MESH_LAST_WAKE:-}" ]; then
        echo "$ACTIVITY_MESH_LAST_WAKE"
        return
    fi
    local boot="" wake="" sc=/usr/sbin/sysctl
    [ -x "$sc" ] || sc=$(command -v sysctl 2>/dev/null || true)
    if [ "$(uname -s)" = Darwin ] && [ -n "$sc" ]; then
        boot=$("$sc" -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
        wake=$("$sc" -n kern.waketime 2>/dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
    elif [ -r /proc/stat ]; then
        boot=$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)
    fi
    case "$boot" in ''|*[!0-9]*) boot=0 ;; esac
    case "$wake" in ''|*[!0-9]*) wake=0 ;; esac
    if [ "$wake" -gt "$boot" ]; then echo "$wake"; else echo "$boot"; fi
}

am_offline_hosts() {
    local state="${OFFLINE_HOSTS_JSON:-$HOME/.claude/channels/telegram/state/offline-hosts.json}"
    [ -r "$state" ] || return 0
    "$AM_JQ" -r 'if type == "object" then keys | join(" ") else empty end' "$state" 2>/dev/null || true
}

am_host_is_offline() {
    local h off o
    h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    off="${2:-}"
    for o in $off; do
        case "$h" in *"$o"*) return 0 ;; esac
    done
    return 1
}

am_emit() {
    local name="$1" tier="$2" status="$3" message="$4"
    local end dur
    end=$(am_now_ms)
    dur=$(( end - CHECK_START_MS ))
    [ "$dur" -lt 0 ] && dur=0
    "$AM_JQ" -cn --arg name "$name" --argjson tier "$tier" --arg status "$status" \
        --arg message "$message" --argjson dur "$dur" \
        '{name: $name, tier: $tier, status: $status, message: $message, duration_ms: $dur}'
}

am_start() {
    local name="${0##*/}"
    if ! command -v "$AM_JQ" >/dev/null 2>&1; then
        printf '{"name":"%s","tier":3,"status":"fail","message":"jq not found","duration_ms":0}\n' "${name%.sh}"
        exit 0
    fi
    CHECK_START_MS=$(am_now_ms); export CHECK_START_MS
}

am_shards() {
    local f
    for f in "$ACTIVITY_MESH_SYNC"/events-*.jsonl; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *.sync-conflict-*) [ "${1:-}" = all ] || continue ;; esac
        printf '%s\n' "$f"
    done
}

am_scan_shards() {
    local pat="$1" strip="${2:-}" f h n hits=0 lines=0 sample=""
    while IFS= read -r f; do
        n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        lines=$(( lines + ${n:-0} ))
        if [ -n "$strip" ]; then
            h=$(LC_ALL=C sed -E "$strip" "$f" 2>/dev/null | grep -cE "$pat" 2>/dev/null)
        else
            h=$(grep -cE "$pat" "$f" 2>/dev/null)
        fi
        case "$h" in ''|*[!0-9]*) h=0 ;; esac
        if [ "$h" -gt 0 ]; then
            hits=$(( hits + h ))
            [ -z "$sample" ] && sample="${f##*/}"
        fi
    done < <(am_shards all)
    printf '%d %d %s\n' "$hits" "$lines" "$sample"
}

am_human_bytes() {
    local b="$1"
    if   [ "$b" -gt 1073741824 ]; then printf '%.1fG' "$(echo "scale=1;$b/1073741824" | bc)"
    elif [ "$b" -gt 1048576 ];    then printf '%.1fM' "$(echo "scale=1;$b/1048576" | bc)"
    elif [ "$b" -gt 1024 ];       then printf '%.1fK' "$(echo "scale=1;$b/1024" | bc)"
    else printf '%dB' "$b"
    fi
}

am_record_alert() {
    local source="$1" severity="$2" log="$ACTIVITY_MESH_STATE/alerts.log"
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source" "$severity" >> "$log" 2>/dev/null || return 0
    if [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 1000 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
    fi
    return 0
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
    local msg="$1" severity="${2:-warn}"
    export NOTIFY_SEVERITY="$severity"
    export NOTIFY_LABEL="${NOTIFY_LABEL:-activity-mesh}"
    if [ -n "${ACTIVITY_MESH_NOTIFY_CMD:-}" ]; then
        # shellcheck disable=SC2086
        printf '%s' "$msg" | ${ACTIVITY_MESH_NOTIFY_CMD} 2>/dev/null && return 0
    fi
    local legacy=""
    if command -v notify-maxim >/dev/null 2>&1; then legacy="notify-maxim"
    elif [ -x "$HOME/.local/bin/notify-maxim" ]; then legacy="$HOME/.local/bin/notify-maxim"
    fi
    if [ -n "$legacy" ]; then
        printf '%s' "$msg" | "$legacy" --severity="$severity" 2>/dev/null && return 0
    fi
    am_notify_telegram "$msg"
}
