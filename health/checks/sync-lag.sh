#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=sync-lag
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

self_host=$(am_host)
now=$(date +%s); worst_lag=0; worst_host=""

for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .jsonl); host=${base#events-}
    [ "$host" = "$self_host" ] && continue   # local host has no sync lag
    # GNU `stat -f` prints the mount point and exits 0, so BSD form goes second.
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
    ctime=$(stat -c %Z "$f" 2>/dev/null || stat -f %c "$f" 2>/dev/null || echo "$mtime")
    age=$(( now - mtime ))
    [ "$age" -gt 86400 ] && continue          # not "live" host, skip
    lag=$(( ctime - mtime ))
    [ "$lag" -lt 0 ] && lag=0
    if [ "$lag" -gt "$worst_lag" ]; then worst_lag=$lag; worst_host=$host; fi
done

if   [ "$worst_lag" -gt 600 ]; then am_emit "$NAME" 3 fail "host=$worst_host delivery lag=${worst_lag}s (>10min)"
elif [ "$worst_lag" -gt 300 ]; then am_emit "$NAME" 2 warn "host=$worst_host delivery lag=${worst_lag}s (>5min)"
else am_emit "$NAME" 1 ok "max delivery lag ${worst_lag}s"
fi
exit 0
