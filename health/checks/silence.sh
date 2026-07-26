#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start

NAME=silence
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing: $SYNC"; exit 0
fi

now=$(date +%s)
worst_age=0; worst_host=""; worst_threshold=0; status_overall=ok

for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .jsonl); host=${base#events-}
    case "$host" in
        macbook)  th=21600 ;;   # 6h
        mac-mini) th=7200 ;;    # 2h
        pc)       th=86400 ;;   # 24h
        *)        th=43200 ;;   # 12h
    esac
    # GNU `stat -f` means "filesystem status" and prints the mount point with
    # exit 0, so the BSD form must be tried SECOND — otherwise every Linux host
    # gets a path here and the age arithmetic silently reads zero.
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
    age=$(( now - mtime ))
    if [ "$age" -gt "$th" ] && [ "$age" -gt "$worst_age" ]; then
        worst_age=$age; worst_host=$host; worst_threshold=$th; status_overall=fail
    fi
done

if [ "$status_overall" = ok ]; then
    am_emit "$NAME" 1 ok "all hosts fresh"
else
    am_emit "$NAME" 3 fail "host=$worst_host age=${worst_age}s threshold=${worst_threshold}s"
fi
exit 0
