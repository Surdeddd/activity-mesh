#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=ulid-collision
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

stats=$(awk 1 "$SYNC"/events-*.jsonl 2>/dev/null | "$AM_JQ" -rR 'fromjson? | .id? // empty' \
    | sort | uniq -c | awk '{ total += $1; if ($1 > 1) dup += $1 - 1 } END { printf "%d %d\n", total + 0, dup + 0 }')
read -r total dup <<< "${stats:-0 0}"

if [ "$total" -eq 0 ]; then
    am_emit "$NAME" 0 ok "no events yet"
elif [ "$dup" -eq 0 ]; then
    am_emit "$NAME" 1 ok "$total ulids all unique"
else
    am_emit "$NAME" 4 critical "$dup duplicate ULIDs out of $total"
fi
exit 0
