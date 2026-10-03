#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=adoption-ratio
SYNC="$ACTIVITY_MESH_SYNC"
WINDOW_S="${ACTIVITY_MESH_ADOPTION_WINDOW_S:-604800}"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

cutoff=$(( $(date +%s) - WINDOW_S ))
stats=$(am_shards | while IFS= read -r f; do awk 1 "$f" 2>/dev/null; done | "$AM_JQ" -nrR --argjson cutoff "$cutoff" "$AM_JQ_DEFS"'
    [inputs | fromjson? | select(type == "object")
     | select(ev_ts >= $cutoff)
     | select((.agent // "") != "heartbeat" and (.kind // "") != "canary"
              and (.kind // "") != "heartbeat" and (.scope // "") != "activity-mesh")
     | (.agent // "unknown")]
    | group_by(.) | map({a: .[0], n: length}) | sort_by(-.n)
    | "\(map(.n) | add // 0) \(length) \(.[0].a // "-") \(.[0].n // 0)"')
read -r total n top max <<< "${stats:-0 0 - 0}"

days=$(( WINDOW_S / 86400 ))
if [ "$n" -eq 0 ]; then
    am_emit "$NAME" 1 warn "no agent events in ${days}d, only self-monitoring"
elif [ "$n" -eq 1 ]; then
    am_emit "$NAME" 1 warn "only $top wrote in ${days}d ($total events)"
else
    others=$(( total - max ))
    ratio=$(awk -v m="$max" -v o="$others" 'BEGIN { printf "%.1f", m / o }')
    if awk -v m="$max" -v o="$others" 'BEGIN { exit !(m > 5 * o) }'; then
        am_emit "$NAME" 1 warn "$top dominates ${ratio}:1 across $n agents in ${days}d ($max of $total events)"
    else
        am_emit "$NAME" 1 ok "balanced: $n agents in ${days}d, top=$top ${ratio}:1"
    fi
fi
exit 0
