#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=redactor-coverage
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

PATS='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|https?://[^[:space:]/]+:[^[:space:]@]+@|/Users/[a-zA-Z]+/|192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+'
GIT_REMOTES='/[Gg][Ii][Tt]@/!b
:a
s#(^|[^A-Za-z0-9._%+-]|\\[nrtbf]|\\u[0-9A-Fa-f]{4})([Gg][Ii][Tt])@([A-Za-z0-9.-]+\.[A-Za-z]{2,}:[A-Za-z0-9_.-]+/)#\1\2 \3#
ta'

read -r hits scanned sample <<< "$(am_scan_shards "$PATS" "$GIT_REMOTES")"

if   [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "0 hits in $scanned lines"
elif [ "$hits" -le 2 ]; then am_emit "$NAME" 2 warn "$hits/$scanned lines with possible PII (e.g. $sample)"
else am_emit "$NAME" 3 fail "$hits/$scanned lines with potential PII (e.g. $sample) — RB-2"
fi
exit 0
