#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=ingester-error
DAEMON_LOG="$ACTIVITY_MESH_STATE/daemon.err"
WATCHER_LOG="$ACTIVITY_MESH_STATE/watcher.err"
WINDOW_S="${ACTIVITY_MESH_HEALTH_WINDOW_S:-21600}"

if [ ! -f "$DAEMON_LOG" ] && [ ! -f "$WATCHER_LOG" ]; then
    am_emit "$NAME" 0 ok "no daemon.err or watcher.err yet"; exit 0
fi

cutoff=$("$AM_JQ" -rn --argjson t $(( $(date +%s) - WINDOW_S )) '$t | strftime("%Y/%m/%d %H:%M:%S")')

count_since() {
    [ -f "$1" ] || { echo 0; return; }
    tail -n 20000 "$1" 2>/dev/null | awk -v c="$cutoff" -v re="$2" '
        /^[0-9][0-9][0-9][0-9]\// && substr($0, 1, 19) >= c && $0 ~ re { n++ }
        END { print n + 0 }'
}

lost_events() {
    [ -f "$1" ] || { echo 0; return; }
    tail -n 20000 "$1" 2>/dev/null | awk -v c="$cutoff" '
        /^[0-9][0-9][0-9][0-9]\// && substr($0, 1, 19) >= c {
            if ($0 ~ / emit error /) n++
            else if ($0 ~ / emit queue full / && match($0, /: [0-9]+ events lost/)) n += substr($0, RSTART + 2) + 0
        }
        END { print n + 0 }'
}

ingest=$(count_since "$DAEMON_LOG" 'ingest failed|periodic ingest:|pre-push ingest:|post-push ingest:| ingest /|server error:|watcher error:|fsnotify:')
lost=$(lost_events "$WATCHER_LOG")

hours=$(( WINDOW_S / 3600 ))
msg="${hours}h: $ingest daemon ingest errors, $lost watcher events lost"
worst=$ingest; [ "$lost" -gt "$worst" ] && worst=$lost
if   [ "$worst" -le 2 ];  then am_emit "$NAME" 1 ok "$msg"
elif [ "$worst" -le 10 ]; then am_emit "$NAME" 2 warn "$msg"
else am_emit "$NAME" 3 fail "$msg"
fi
exit 0
