#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=size-guard
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing"; exit 0
fi

if du -sk "$SYNC" >/dev/null 2>&1; then
    bytes_kb=$(du -sk "$SYNC" 2>/dev/null | awk '{print $1}')
    bytes=$(( bytes_kb * 1024 ))
else
    bytes=0
fi

human=$(am_human_bytes "$bytes")
if   [ "$bytes" -gt $((500*1024*1024)) ]; then am_emit "$NAME" 3 fail "size $human exceeds 500MB"
elif [ "$bytes" -gt $((400*1024*1024)) ]; then am_emit "$NAME" 2 warn "size $human exceeds 400MB warn"
else am_emit "$NAME" 1 ok "size $human"; fi
exit 0
