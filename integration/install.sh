#!/bin/bash

set -uo pipefail

TARGET="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

err() { echo "install: $*" >&2; }
say() { echo "install: $*"; }

[ -f "$TARGET" ] || { err "target not found: $TARGET"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 required"; exit 1; }

END_MARKER='<!-- activity-mesh:integration:end -->'

if grep -qF "$END_MARKER" "$TARGET"; then
    say "already patched (end-marker present); nothing to do"
    exit 0
fi

read -r -d '' BLOCK <<'EOF' || true
> activity-mesh integration — operational-history layer

| что | где | роль |
|---|---|---|
| **operational history** (что-кто-когда-сделал, cross-machine) | **activity-mesh**: `~/Sync/activity/events-<host>.jsonl` + daemon на `:7459` | timeline queries, cross-machine awareness. **NOT state truth** — это history |

**Lookup order**:

1. **State queries** ("что IS правило для X / current preference for Y") → `MEMORY.md`
2. **Knowledge queries** ("какой pattern для X / how do we handle Y") → wiki
3. **Timeline queries** ("WHEN произошло X / WHO сделал X") → **activity-mesh** (`activity_recent` MCP / `activity-log query` CLI)
4. **Recall queries** ("вещи related to X") → mempalace
5. **Channel queries** (bridge-specific state) → bridge memory

**Rule**: activity-mesh = HISTORY, не STATE TRUTH. Не цитировать activity events as "current state" — query MEMORY первым. Activity events answer **WHEN/WHO**, MEMORY answers **WHAT IS**.

`activity_recent` MCP tool auto-loaded; auto-context инжектится через UserPromptSubmit hook (see `~/.claude/hooks/user-prompt-router.sh`). Если не injected — call the tool. Никогда не "не знаю" про operational history если демон жив.

<!-- activity-mesh:integration:end -->
EOF

TMP=$(mktemp)
python3 - "$TARGET" "$TMP" <<PYEOF "$BLOCK"
import sys, re
target, tmp = sys.argv[1], sys.argv[2]
block = sys.argv[3]
with open(target, encoding="utf-8") as f:
    src = f.read()

header_re = re.compile(r"^## Memory canonical sources.*?$", re.MULTILINE)
m = header_re.search(src)
if m is None:
    appended = "\n## Memory canonical sources (не путать)\n\n"
    appended += "| что | где | роль |\n|---|---|---|\n"
    appended += "| **state truth** (active rules, current preferences, infrastructure facts) | \`~/.claude/projects/-Users-maksimkravcov/memory/MEMORY.md\` + .md files | always-on |\n"
    appended += "| **compoundable patterns / decisions** | \`~/Obsidian/llm-wiki/\` | wiki growth |\n"
    appended += block + "\n"
    out = src.rstrip() + "\n" + appended
else:
    after = src[m.end():]
    next_h2 = re.search(r"^#{1,2} ", after, re.MULTILINE)
    if next_h2 is None:
        out = src.rstrip() + "\n\n" + block + "\n"
    else:
        insertion_point = m.end() + next_h2.start()
        out = src[:insertion_point] + block + "\n\n" + src[insertion_point:]

with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
PYEOF

if ! grep -qF "$END_MARKER" "$TMP"; then
    err "post-patch sanity failed: end-marker missing"
    rm -f "$TMP"; exit 1
fi
if ! grep -qF "operational history" "$TMP"; then
    err "post-patch sanity failed: operational-history row missing"
    rm -f "$TMP"; exit 1
fi

if diff -u "$TARGET" "$TMP" > /dev/null 2>&1; then
    say "no changes (already up to date)"
    rm -f "$TMP"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY RUN: diff ==="
    diff -u "$TARGET" "$TMP" || true
    rm -f "$TMP"
    exit 0
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${TARGET}.bak-${STAMP}"
cp "$TARGET" "$BACKUP" || { err "backup failed"; rm -f "$TMP"; exit 1; }

if mv "$TMP" "$TARGET"; then
    say "applied. backup at $BACKUP"
    exit 0
else
    err "write failed; restoring backup"
    mv "$BACKUP" "$TARGET" 2>/dev/null
    rm -f "$TMP"
    exit 1
fi
