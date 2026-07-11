#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=ulid-collision
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

total=0; uniq=0
ALL=$(mktemp)
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/jq -r '.id // empty' 2>/dev/null)
        [ -z "$id" ] && continue
        total=$((total+1))
        printf '%s\n' "$id" >> "$ALL"
    done < <(tail -n 1000 "$f" 2>/dev/null)
done

if [ "$total" -eq 0 ]; then
    rm -f "$ALL"
    am_emit "$NAME" 0 ok "no events yet"; exit 0
fi
uniq=$(/usr/bin/sort -u "$ALL" | /usr/bin/wc -l | tr -d ' ')
rm -f "$ALL"
dup=$(( total - uniq ))

if [ "$dup" -eq 0 ]; then am_emit "$NAME" 1 ok "$total ulids all unique"
else am_emit "$NAME" 4 critical "$dup duplicate ULIDs out of $total"
fi
exit 0
