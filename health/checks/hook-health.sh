#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=hook-health
LOG_DIR="$ACTIVITY_MESH_STATE"
WINDOW_S="${ACTIVITY_MESH_HEALTH_WINDOW_S:-21600}"

if [ ! -d "$LOG_DIR" ]; then
    am_emit "$NAME" 2 warn "log dir missing"; exit 0
fi

cutoff=$("$AM_JQ" -rn --argjson t $(( $(date +%s) - WINDOW_S )) '$t | todate')
errors=0; sample=""
for log in session-start.log user-prompt-router.log redactor.log; do
    f="$LOG_DIR/$log"
    [ -f "$f" ] || continue
    n=$(tail -n 5000 "$f" 2>/dev/null | awk -v c="[$cutoff]" '
        /^\[[0-9][0-9][0-9][0-9]-/ && substr($0, 1, length(c)) >= c && tolower($0) ~ /error|fail|no binary|not found|no jq/ { n++ }
        END { print n + 0 }')
    if [ "$n" -gt 0 ]; then
        errors=$(( errors + n ))
        [ -z "$sample" ] && sample="$log"
    fi
done

hours=$(( WINDOW_S / 3600 ))
if   [ "$errors" -eq 0 ]; then am_emit "$NAME" 1 ok "0 hook errors in ${hours}h"
elif [ "$errors" -le 5 ]; then am_emit "$NAME" 2 warn "$errors hook errors in ${hours}h (e.g. $sample)"
else am_emit "$NAME" 3 fail "$errors hook errors in ${hours}h (e.g. $sample)"
fi
exit 0
