#!/bin/bash
# digest-freshness — `now - generated_at` of latest digest file.
# Digest expected at $ACTIVITY_MESH_STATE/last-digest.json with .generated_at epoch.
# The writer is the WEEKLY digest job, so thresholds are calendar-scaled:
# >8d fail (one missed run + slack), >7d12h warn. The original 2h threshold
# guaranteed a permanent red ~99% of every week — pure alert fatigue.

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

FAIL_S=$(( 8 * 86400 ))
WARN_S=$(( 7 * 86400 + 43200 ))
if   [ "$drift" -gt "$FAIL_S" ]; then am_emit "$NAME" 3 fail "digest drift ${drift}s (>8d — weekly job missed)"
elif [ "$drift" -gt "$WARN_S" ]; then am_emit "$NAME" 2 warn "digest drift ${drift}s (>7.5d)"
else am_emit "$NAME" 1 ok "digest drift ${drift}s"
fi
exit 0
