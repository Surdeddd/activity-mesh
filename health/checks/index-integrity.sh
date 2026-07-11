#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=index-integrity
DB="$ACTIVITY_MESH_HOME/index.db"

if ! command -v sqlite3 >/dev/null 2>&1; then
    am_emit "$NAME" 2 warn "sqlite3 not installed"; exit 0
fi
if [ ! -f "$DB" ]; then
    am_emit "$NAME" 0 ok "index.db not present yet"; exit 0
fi

result=$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 | head -3 | tr '\n' ';' | sed 's/;$//')
if [ "$result" = "ok" ]; then
    am_emit "$NAME" 1 ok "integrity ok"
else
    am_emit "$NAME" 4 critical "integrity_check failed: $result"
fi
exit 0
