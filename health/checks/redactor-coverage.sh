#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=redactor-coverage
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

PATS='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|https?://[^[:space:]/]+:[^[:space:]@]+@|/Users/[a-zA-Z]+/|192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+'

sampled=0; hits=0; sample=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    total_lines=$(wc -l < "$f" 2>/dev/null || echo 0)
    [ "$total_lines" -lt 1 ] && continue
    take=$(( total_lines / 100 )); [ "$take" -lt 1 ] && take=1
    [ "$take" -gt 100 ] && take=100
    while IFS= read -r line; do
        sampled=$((sampled+1))
        if printf '%s' "$line" | grep -qE "$PATS"; then
            hits=$((hits+1))
            [ -z "$sample" ] && sample="$(basename "$f")"
        fi
    done < <(awk -v n="$take" 'BEGIN{srand()} {if (rand()<n/NR) print}' "$f" 2>/dev/null | head -n "$take")
done

if   [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "0 hits in $sampled sampled"
elif [ "$hits" -le 2 ]; then am_emit "$NAME" 2 warn "$hits/$sampled possible PII (e.g. $sample)"
else am_emit "$NAME" 3 fail "$hits/$sampled potential PII (e.g. $sample) — RB-2"
fi
exit 0
