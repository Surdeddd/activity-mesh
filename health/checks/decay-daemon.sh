#!/bin/bash
# decay-daemon — verifies memory-decay/compactor ran within last 7 days.
# State file: $ACTIVITY_MESH_STATE/decay-state.json with field last_run_ts.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=decay-daemon
STATE="$ACTIVITY_MESH_STATE/decay-state.json"

if [ ! -f "$STATE" ]; then
    am_emit "$NAME" 2 warn "decay-state.json missing — compactor may have never run"; exit 0
fi

last=$(/usr/bin/jq -r '.last_run_ts // 0' "$STATE" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
now=$(date +%s); age=$(( now - last ))

if   [ "$age" -gt $((14*86400)) ]; then am_emit "$NAME" 3 fail  "decay last ran ${age}s ago (>14d)"
elif [ "$age" -gt $((7*86400)) ];  then am_emit "$NAME" 2 warn  "decay last ran ${age}s ago (>7d)"
else am_emit "$NAME" 1 ok "decay ran ${age}s ago"
fi
exit 0
