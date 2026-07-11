#!/bin/bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
SESSION_HOOK="$HERE/session-start-digest.sh"
PROMPT_HOOK="$HERE/user-prompt-router.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

err() { echo "install: $*" >&2; }

[ -f "$SETTINGS" ] || { err "settings.json not found at $SETTINGS"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq required"; exit 1; }
[ -x "$SESSION_HOOK" ] || chmod +x "$SESSION_HOOK" 2>/dev/null
[ -x "$PROMPT_HOOK" ] || chmod +x "$PROMPT_HOOK" 2>/dev/null

if ! jq empty "$SETTINGS" 2>/dev/null; then
    err "settings.json is not valid JSON; aborting"
    exit 1
fi

PATCHED=$(jq \
    --arg sess "$SESSION_HOOK" \
    --arg prompt "$PROMPT_HOOK" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.UserPromptSubmit //= [] |
    if (.hooks.SessionStart | map(.hooks // [] | map(.command)) | flatten | index($sess)) then .
    else .hooks.SessionStart += [{"matcher":"","hooks":[{"type":"command","command":$sess}]}]
    end |
    if (.hooks.UserPromptSubmit | map(.hooks // [] | map(.command)) | flatten | index($prompt)) then .
    else .hooks.UserPromptSubmit += [{"matcher":"","hooks":[{"type":"command","command":$prompt}]}]
    end
' "$SETTINGS") || { err "jq patch failed"; exit 1; }

TMP_OLD=$(mktemp); TMP_NEW=$(mktemp)
jq -S . "$SETTINGS" > "$TMP_OLD"
printf '%s\n' "$PATCHED" | jq -S . > "$TMP_NEW"

if diff -u "$TMP_OLD" "$TMP_NEW" > /dev/null 2>&1; then
    rm -f "$TMP_OLD" "$TMP_NEW"
    echo "install: hooks already wired, nothing to do"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY RUN: diff ==="
    diff -u "$TMP_OLD" "$TMP_NEW" || true
    rm -f "$TMP_OLD" "$TMP_NEW"
    exit 0
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${SETTINGS}.bak-${STAMP}"
cp "$SETTINGS" "$BACKUP" || { err "backup failed"; rm -f "$TMP_OLD" "$TMP_NEW"; exit 1; }

if printf '%s\n' "$PATCHED" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"; then
    rm -f "$TMP_OLD" "$TMP_NEW"
    echo "install: applied. backup at $BACKUP"
    exit 0
else
    err "write failed; restoring backup"
    mv "$BACKUP" "$SETTINGS" 2>/dev/null
    rm -f "$TMP_OLD" "$TMP_NEW" "${SETTINGS}.tmp"
    exit 1
fi
