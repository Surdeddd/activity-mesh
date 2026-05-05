#!/bin/bash
# digest-freshness — `now - generated_at` of latest digest file.
# Digest expected at $ACTIVITY_MESH_STATE/last-digest.json with .generated_at epoch.
# Drift > 2h → fail.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=digest-freshness
F="$ACTIVITY_MESH_STATE/last-digest.json"

if [ ! -f "$F" ]; then
    am_emit "$NAME" 2 warn "no digest snapshot yet"; exit 0
fi

gen=$(/usr/bin/jq -r '.generated_at // 0' "$F" 2>/dev/null || echo 0)
case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
now=$(date +%s); drift=$(( now - gen ))

if   [ "$drift" -gt 7200 ]; then am_emit "$NAME" 3 fail "digest drift ${drift}s (>2h)"
elif [ "$drift" -gt 3600 ]; then am_emit "$NAME" 2 warn "digest drift ${drift}s (>1h)"
else am_emit "$NAME" 1 ok "digest drift ${drift}s"
fi
exit 0
