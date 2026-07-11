#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=token-budget

INJ_LOG="$ACTIVITY_MESH_STATE/injections.log"
PER_FIRE_CAP=500
SESSION_CAP=2000

inj_stats=""
if [ -f "$INJ_LOG" ] && [ -s "$INJ_LOG" ]; then
    inj_stats=$(/usr/bin/tail -n 1000 "$INJ_LOG" | awk '{print $3}' | grep -E '^[0-9]+$' | sort -n | awk '
        { vals[NR] = $1 }
        END {
            if (NR == 0) exit
            p50 = vals[int((NR - 1) * 0.50) + 1]
            p95 = vals[int((NR - 1) * 0.95) + 1]
            printf "n=%d p50=%d p95=%d max=%d", NR, p50, p95, vals[NR]
        }')
fi

max_session=0
shopt -s nullglob 2>/dev/null
for f in "$ACTIVITY_MESH_STATE"/tokens-*; do
    [ -f "$f" ] || continue
    v=$(tr -d '[:space:]' < "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -gt "$max_session" ] && max_session=$v
done
shopt -u nullglob 2>/dev/null

if [ -z "$inj_stats" ]; then
    am_emit "$NAME" 0 ok "no injection telemetry yet (max_session=$max_session/$SESSION_CAP)"; exit 0
fi

p95=$(printf '%s' "$inj_stats" | grep -oE 'p95=[0-9]+' | cut -d= -f2)
maxv=$(printf '%s' "$inj_stats" | grep -oE 'max=[0-9]+' | cut -d= -f2)
case "$p95" in ''|*[!0-9]*) p95=0 ;; esac
case "$maxv" in ''|*[!0-9]*) maxv=0 ;; esac

msg="per-fire $inj_stats (cap $PER_FIRE_CAP); max_session=$max_session/$SESSION_CAP"
if   [ "$p95" -gt "$PER_FIRE_CAP" ]; then am_emit "$NAME" 3 fail "$msg — p95 over per-fire cap"
elif [ "$maxv" -gt "$PER_FIRE_CAP" ]; then am_emit "$NAME" 2 warn "$msg — max over per-fire cap"
elif [ "$max_session" -gt "$SESSION_CAP" ]; then am_emit "$NAME" 2 warn "$msg — a session exceeded its cumulative cap"
else am_emit "$NAME" 1 ok "$msg"
fi
exit 0
