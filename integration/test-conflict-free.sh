#!/bin/bash

set -uo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
SKIP=0

ok()   { green   "  ok    $*"; PASS=$((PASS+1)); }
bad()  { red     "  FAIL  $*"; FAIL=$((FAIL+1)); }
skip() { yellow  "  skip  $*"; SKIP=$((SKIP+1)); }

NONCE="conflict-test-$(date -u +%s)-$RANDOM"

echo "== conflict-free verify =="
echo "nonce: $NONCE"
echo

count_match() {
    local needle="$1"
    grep -c -F -- "$needle" 2>/dev/null | head -1 || true
}

if ! command -v activity-log >/dev/null 2>&1; then
    red "activity-log binary not on PATH; aborting"
    exit 2
fi

if ! activity-log status >/dev/null 2>&1; then
    yellow "activity-log not initialised; running 'activity-log init --yes' for test"
    activity-log init --yes >/dev/null 2>&1 || {
        red "activity-log init failed; aborting"
        exit 2
    }
fi

EMIT_OUT=$(activity-log emit \
    --kind canary \
    --scope activity-mesh \
    --summary "$NONCE conflict-test event" \
    --tags conflict-test \
    --agent claude-mac 2>&1)
EMIT_RC=$?
EID=$(echo "$EMIT_OUT" | tail -1)
if [ "$EMIT_RC" -ne 0 ] || [ -z "$EID" ] || echo "$EID" | grep -q "error"; then
    bad "emit failed: rc=$EMIT_RC out=$EMIT_OUT"
    exit 1
fi
ok "emit ok: $EID"

sleep 5

COUNT=$(activity-log query --since 5m 2>/dev/null | count_match "$NONCE")
COUNT=${COUNT:-0}
if [ "$COUNT" -eq 1 ]; then
    ok "activity-log query: 1 hit"
elif [ "$COUNT" -eq 0 ]; then
    bad "activity-log query: 0 hits (event not found)"
else
    bad "activity-log query: $COUNT hits (duplicate write detected)"
fi

if curl -sf "http://127.0.0.1:7459/health" >/dev/null 2>&1; then
    HTTP_COUNT=$(curl -sf "http://127.0.0.1:7459/recent?limit=50" 2>/dev/null | count_match "$NONCE")
    HTTP_COUNT=${HTTP_COUNT:-0}
    if [ "$HTTP_COUNT" -eq 1 ]; then
        ok "daemon :7459/recent: 1 hit"
    elif [ "$HTTP_COUNT" -eq 0 ]; then
        bad "daemon :7459/recent: 0 hits (sync lag or indexer down)"
    else
        bad "daemon :7459/recent: $HTTP_COUNT hits (duplicate)"
    fi
else
    skip "daemon :7459 not up — skipping HTTP reader checks"
fi

if command -v mempalace >/dev/null 2>&1; then
    MEMP_COUNT=$(mempalace search "$NONCE" 2>/dev/null | count_match "$NONCE")
    MEMP_COUNT=${MEMP_COUNT:-0}
    if [ "$MEMP_COUNT" -le 1 ]; then
        ok "mempalace search: $MEMP_COUNT hits (≤1 acceptable)"
    else
        bad "mempalace search: $MEMP_COUNT hits (duplicate)"
    fi
else
    skip "mempalace CLI not on PATH — skipping"
fi

MEMORY_FILE="$HOME/.claude/projects/-Users-maksimkravcov/memory/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
    if grep -qF "$NONCE" "$MEMORY_FILE"; then
        bad "MEMORY.md contains nonce — activity events leaked into state truth!"
    else
        ok "MEMORY.md has no nonce — boundary holds"
    fi
else
    skip "MEMORY.md not found at $MEMORY_FILE — skipping leak check"
fi

WIKI_LOG="$HOME/Obsidian/llm-wiki/log.md"
if [ -f "$WIKI_LOG" ]; then
    if grep -qF "$NONCE" "$WIKI_LOG"; then
        bad "wiki/log.md contains nonce — compiler audit leaked direct writes"
    else
        ok "wiki/log.md has no nonce — compiler-only invariant holds"
    fi
else
    skip "wiki/log.md not found — skipping leak check"
fi

BRIDGE_DIR="$HOME/.claude/channels/telegram/memory"
if [ -d "$BRIDGE_DIR" ]; then
    if grep -rqF "$NONCE" "$BRIDGE_DIR" 2>/dev/null; then
        bad "bridge memory contains nonce — bridge wrote when it should only read"
    else
        ok "bridge memory clean — read-only invariant holds"
    fi
else
    skip "bridge memory dir not found — skipping"
fi

echo
echo "== summary =="
echo "  pass: $PASS   fail: $FAIL   skip: $SKIP"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
