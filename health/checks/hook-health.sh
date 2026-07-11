#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=hook-health
LOG_DIR="$ACTIVITY_MESH_STATE"

if [ ! -d "$LOG_DIR" ]; then
    am_emit "$NAME" 2 warn "log dir missing"; exit 0
fi

now=$(date +%s); cutoff=$(( now - 3600 ))
errors=0; sample=""
for log in "$LOG_DIR"/*.log; do
    [ -f "$log" ] || continue
    while IFS= read -r line; do
        ts=$(printf '%s' "$line" | grep -oE '\[[^]]+\]' | head -1 | tr -d '[]')
        ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
                  || date -u -d "$ts" +%s 2>/dev/null || echo 0)
        [ "$ts_epoch" -lt "$cutoff" ] && continue
        if printf '%s' "$line" | grep -qiE 'error|fail'; then
            errors=$((errors+1))
            [ -z "$sample" ] && sample=$(basename "$log")
        fi
    done < <(tail -n 200 "$log" 2>/dev/null)
done

if   [ "$errors" -eq 0 ]; then am_emit "$NAME" 1 ok "0 errors in last hour"
elif [ "$errors" -le 5 ]; then am_emit "$NAME" 2 warn "$errors errors (e.g. $sample)"
else am_emit "$NAME" 3 fail "$errors errors (e.g. $sample)"
fi
exit 0
