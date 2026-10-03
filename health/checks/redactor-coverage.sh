#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=redactor-coverage
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

PATS='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|https?://[^[:space:]/]+:[^[:space:]@]+@|/Users/[a-zA-Z]+/|192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+'

scanned=0; hits=0; sample=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    scanned=$(( scanned + ${lines:-0} ))
    h=$(grep -cE "$PATS" "$f" 2>/dev/null)
    case "$h" in ''|*[!0-9]*) h=0 ;; esac
    if [ "$h" -gt 0 ]; then
        hits=$(( hits + h ))
        [ -z "$sample" ] && sample="${f##*/}"
    fi
done

if   [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "0 hits in $scanned lines"
elif [ "$hits" -le 2 ]; then am_emit "$NAME" 2 warn "$hits/$scanned lines with possible PII (e.g. $sample)"
else am_emit "$NAME" 3 fail "$hits/$scanned lines with potential PII (e.g. $sample) — RB-2"
fi
exit 0
