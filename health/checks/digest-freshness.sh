#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=digest-freshness
F="$ACTIVITY_MESH_STATE/last-digest.json"

if [ ! -f "$F" ]; then
    am_emit "$NAME" 0 ok "no local digest (runs on the designated digest host)"; exit 0
fi

gen=$(/usr/bin/jq -r '.generated_at // 0' "$F" 2>/dev/null || echo 0)
case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
now=$(date +%s); drift=$(( now - gen ))

FAIL_S=$(( 8 * 86400 ))
WARN_S=$(( 7 * 86400 + 43200 ))
if   [ "$drift" -gt "$FAIL_S" ]; then am_emit "$NAME" 3 fail "digest drift ${drift}s (>8d — weekly job missed)"
elif [ "$drift" -gt "$WARN_S" ]; then am_emit "$NAME" 2 warn "digest drift ${drift}s (>7.5d)"
else am_emit "$NAME" 1 ok "digest drift ${drift}s"
fi
exit 0
