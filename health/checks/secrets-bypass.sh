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

read -r hits _ sample <<< "$(am_scan_shards "$PATS")"

if [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "no secrets in live shards"
else am_emit "$NAME" 4 critical "$hits lines with potential secrets in $sample (run RB-2 immediately)"; fi
exit 0
