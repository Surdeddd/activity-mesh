#!/bin/bash
# ingester-error — count failed ingests in last hour.
# Reads $ACTIVITY_MESH_STATE/ingest.log lines like "ERROR ingest..." with timestamps.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=ingester-error
LOG="$ACTIVITY_MESH_STATE/ingest.log"

if [ ! -f "$LOG" ]; then
    am_emit "$NAME" 0 ok "no ingest.log yet"; exit 0
fi

now=$(date +%s); cutoff=$(( now - 3600 )); errors=0
while IFS= read -r line; do
    ts=$(printf '%s' "$line" | grep -oE '\[[^]]+\]' | head -1 | tr -d '[]')
    ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
              || date -u -d "$ts" +%s 2>/dev/null || echo 0)
    [ "$ts_epoch" -lt "$cutoff" ] && continue
    if printf '%s' "$line" | grep -qiE 'error|fail'; then errors=$((errors+1)); fi
done < <(tail -n 500 "$LOG" 2>/dev/null)

if   [ "$errors" -le 3 ]; then am_emit "$NAME" 1 ok "$errors errors / hr"
elif [ "$errors" -le 10 ]; then am_emit "$NAME" 2 warn "$errors errors / hr"
else am_emit "$NAME" 3 fail "$errors errors / hr"
fi
exit 0
