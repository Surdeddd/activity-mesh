#!/bin/bash
# decay-daemon — verifies the compactor ran recently. `activity-log compact`
# writes $ACTIVITY_MESH_STATE/decay-state.json (last_run_ts) on every run,
# archived-something or not. The compact job is MONTHLY, so thresholds are
# calendar-scaled: >40d fail (one missed run + slack), >32d warn. The old
# 14d/7d thresholds fired for half of every normal month.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=decay-daemon
STATE="$ACTIVITY_MESH_STATE/decay-state.json"

if [ ! -f "$STATE" ]; then
    am_emit "$NAME" 2 warn "decay-state.json missing — compactor has not run yet"; exit 0
fi

last=$(/usr/bin/jq -r '.last_run_ts // 0' "$STATE" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
now=$(date +%s); age=$(( now - last ))

if   [ "$age" -gt $((40*86400)) ]; then am_emit "$NAME" 3 fail  "compact last ran ${age}s ago (>40d — monthly job missed)"
elif [ "$age" -gt $((32*86400)) ];  then am_emit "$NAME" 2 warn  "compact last ran ${age}s ago (>32d)"
else am_emit "$NAME" 1 ok "compact ran ${age}s ago"
fi
exit 0
