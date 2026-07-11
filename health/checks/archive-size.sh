#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=archive-size
ARCHIVE="$ACTIVITY_MESH_SYNC/archive"

if [ ! -d "$ARCHIVE" ]; then
    am_emit "$NAME" 0 ok "no archive dir yet (compactor not run)"; exit 0
fi

count=$(find "$ARCHIVE" -type f \( -name '*.zst' -o -name '*.gz' -o -name '*.xz' \) 2>/dev/null | wc -l | tr -d ' ')
plain=$(find "$ARCHIVE" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')

stale=$(find "$ARCHIVE" -type f -name '*.jsonl' -mtime +30 2>/dev/null | wc -l | tr -d ' ')

if [ "$stale" -gt 0 ]; then
    am_emit "$NAME" 2 warn "$stale uncompressed jsonl files >30d old"
elif [ "$count" -eq 0 ] && [ "$plain" -eq 0 ]; then
    am_emit "$NAME" 0 ok "archive empty"
else
    am_emit "$NAME" 1 ok "$count compressed, $plain plain"
fi
exit 0
