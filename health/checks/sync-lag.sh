#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=sync-lag
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

self_host=$(am_host)
now=$(date +%s); wake=$(am_last_wake); worst_lag=0; worst_host=""

while IFS= read -r f; do
    base=${f##*/}; base=${base%.jsonl}; host=${base#events-}
    [ "$host" = "$self_host" ] && continue
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
    ctime=$(stat -c %Z "$f" 2>/dev/null || stat -f %c "$f" 2>/dev/null || echo "$mtime")
    [ $(( now - mtime )) -gt 86400 ] && continue
    start=$mtime
    if [ "$wake" -gt "$mtime" ] && [ "$ctime" -ge "$wake" ]; then start=$wake; fi
    lag=$(( ctime - start ))
    [ "$lag" -lt 0 ] && lag=0
    if [ "$lag" -gt "$worst_lag" ]; then worst_lag=$lag; worst_host=$host; fi
done < <(am_shards)

if   [ "$worst_lag" -gt 600 ]; then am_emit "$NAME" 3 fail "host=$worst_host delivery lag=${worst_lag}s (>10min)"
elif [ "$worst_lag" -gt 300 ]; then am_emit "$NAME" 2 warn "host=$worst_host delivery lag=${worst_lag}s (>5min)"
else am_emit "$NAME" 1 ok "max delivery lag ${worst_lag}s"
fi
exit 0
