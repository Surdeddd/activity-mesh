#!/bin/bash
# health/lib.sh — shared helpers for all 19 health checks.
# Source via:  . "$(dirname "$0")/../lib.sh"
# Each check produces one JSON line on stdout. Always exit 0 — orchestrator interprets.

# shellcheck shell=bash

set -uo pipefail

: "${ACTIVITY_MESH_SYNC:=$HOME/Sync/activity}"
: "${ACTIVITY_MESH_STATE:=$HOME/.local/state/activity-mesh}"
: "${ACTIVITY_MESH_HOME:=$HOME/.local/share/activity-mesh}"
: "${ACTIVITY_MESH_LOG:=$HOME/.local/state/activity-mesh}"
mkdir -p "$ACTIVITY_MESH_STATE" "$ACTIVITY_MESH_LOG" 2>/dev/null || true

# host detection (reused by silence/canary/sync-lag)
am_host() {
    case "$(uname -s)" in
        Darwin) hn=$(hostname -s 2>/dev/null || echo unknown)
                case "$hn" in *macbook*|*MacBook*) echo macbook ;;
                              *macmini*|*Mac-mini*|*mini*) echo mac-mini ;;
                              *) echo "$hn" ;; esac ;;
        Linux)  hostname -s 2>/dev/null || echo linux ;;
        *)      echo unknown ;;
    esac
}

# ms timestamp (portable)
am_now_ms() {
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s%3N
    else
        # BSD date doesn't support %3N. Probe for GNU; fall back to python3 then to second-resolution.
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

# emit one result JSON line: name, tier (0-4), status, message
# duration_ms inferred from CHECK_START_MS (set by start_check)
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

# Record start; cheap. Each check sets CHECK_START_MS at top.
am_start() { CHECK_START_MS=$(am_now_ms); export CHECK_START_MS; }

# Bytes → human readable
am_human_bytes() {
    local b="$1"
    if   [ "$b" -gt 1073741824 ]; then printf '%.1fG' "$(echo "scale=1;$b/1073741824" | bc)"
    elif [ "$b" -gt 1048576 ];    then printf '%.1fM' "$(echo "scale=1;$b/1048576" | bc)"
    elif [ "$b" -gt 1024 ];       then printf '%.1fK' "$(echo "scale=1;$b/1024" | bc)"
    else printf '%dB' "$b"
    fi
}
