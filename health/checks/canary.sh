#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=canary
SYNC="$ACTIVITY_MESH_SYNC"
host=$(am_host)
F="$SYNC/events-$host.jsonl"

if [ ! -f "$F" ]; then
    am_emit "$NAME" 2 warn "host shard $F missing"; exit 0
fi

now=$(date +%s); cutoff=$(( now - 86400 ))
count=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind=$(printf '%s' "$line" | /usr/bin/jq -r '.kind // empty' 2>/dev/null)
    [ "$kind" = canary ] || continue
    ts=$(printf '%s' "$line" | /usr/bin/jq -r '.ts // empty' 2>/dev/null)
    ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
              || date -u -d "$ts" +%s 2>/dev/null || echo 0)
    [ "$ts_epoch" -lt "$cutoff" ] && continue
    count=$((count+1))
done < <(tail -n 500 "$F" 2>/dev/null)

if   [ "$count" -ge 20 ]; then am_emit "$NAME" 1 ok "$count canary events / 24h"
elif [ "$count" -ge 10 ]; then am_emit "$NAME" 2 warn "$count canary events (expected ≥20)"
else am_emit "$NAME" 3 fail "$count canary events / 24h (writer/launchd issue)"
fi
exit 0
