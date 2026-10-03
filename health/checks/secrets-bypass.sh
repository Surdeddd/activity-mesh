#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=secrets-bypass
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing"; exit 0
fi

PATS='sk-ant-[A-Za-z0-9_-]{32,}|sk-[A-Za-z0-9]{40,}|ghp_[A-Za-z0-9]{30,}|xox[abposr]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|AIza[A-Za-z0-9_-]{30,}|-----BEGIN [A-Z ]+PRIVATE KEY-----'

hits=0; sample=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    h=$(grep -cE "$PATS" "$f" 2>/dev/null)
    case "$h" in ''|*[!0-9]*) h=0 ;; esac
    if [ "$h" -gt 0 ]; then
        hits=$(( hits + h ))
        [ -z "$sample" ] && sample="${f##*/}"
    fi
done

if [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "no secrets in live shards"
else am_emit "$NAME" 4 critical "$hits lines with potential secrets in $sample (run RB-2 immediately)"; fi
exit 0
