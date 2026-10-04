#!/bin/bash

set -uo pipefail

HOOK="${SESSION_END_HOOK:-$HOME/.claude/hooks/session-end-flush.sh}"

err() { echo "update-flush: $*" >&2; }
say() { echo "update-flush: $*"; }

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) echo "usage: update-session-end-flush.sh [--dry-run]   (SESSION_END_HOOK=<file> overrides ~/.claude/hooks/session-end-flush.sh)"; exit 0 ;;
        *) err "unknown argument: $arg"; exit 2 ;;
    esac
done

write_through() {
    local real="$1" n=0 t mode tmp
    while [ -L "$real" ] && [ "$n" -lt 20 ]; do
        t="$(readlink "$real")"
        case "$t" in /*) real="$t" ;; *) real="$(dirname "$real")/$t" ;; esac
        n=$((n + 1))
    done
    mode="$(stat -c %a "$real" 2>/dev/null || stat -f %Lp "$real" 2>/dev/null)" || mode=""
    tmp="$(mktemp "$real.XXXXXX")" || return 1
    if cat > "$tmp" && { [ -z "$mode" ] || chmod "$mode" "$tmp"; } && mv -f "$tmp" "$real"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

[ -f "$HOOK" ] || { err "hook not found: $HOOK"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 required"; exit 1; }

MARKER='# activity-mesh: emit session-summary event'

if grep -qF "$MARKER" "$HOOK"; then
    say "already patched (marker present); nothing to do"
    exit 0
fi

read -r -d '' INJECT <<'EOF' || true
# activity-mesh: emit session-summary event
if command -v activity-log >/dev/null 2>&1; then
    SUMMARY_TXT="claude-mac session ${SESSION_ID:-unknown} ended (cwd=${CWD:-?})"
    activity-log emit \
        --kind note \
        --scope claude-mac \
        --summary "$SUMMARY_TXT" \
        --tags session-end,claude-code \
        --agent claude-mac \
        >/dev/null 2>&1 || true
fi

EOF

TMP=$(mktemp)
python3 - "$HOOK" "$TMP" "$INJECT" <<'PYEOF'
import sys, re
hook, tmp, inject = sys.argv[1], sys.argv[2], sys.argv[3]
with open(hook, encoding="utf-8") as f:
    src = f.read()
m = re.search(r"^mv \"\$STAGE_OUT\" \"\$OUT\"", src, re.MULTILINE)
if m is None:
    sys.stderr.write("update-flush: could not find `mv \"$STAGE_OUT\" \"$OUT\"` line\n")
    sys.exit(2)
insertion = m.start()
out = src[:insertion] + inject + "\n" + src[insertion:]
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
PYEOF

if [ ! -s "$TMP" ]; then
    err "patch generation failed"
    rm -f "$TMP"; exit 1
fi

if ! grep -qF "$MARKER" "$TMP"; then
    err "post-patch sanity failed: marker missing"
    rm -f "$TMP"; exit 1
fi

if diff -u "$HOOK" "$TMP" > /dev/null 2>&1; then
    say "no changes (already up to date)"
    rm -f "$TMP"; exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY RUN: diff ==="
    diff -u "$HOOK" "$TMP" || true
    rm -f "$TMP"; exit 0
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${HOOK}.bak-${STAMP}"
cp "$HOOK" "$BACKUP" || { err "backup failed"; rm -f "$TMP"; exit 1; }

if write_through "$HOOK" < "$TMP"; then
    rm -f "$TMP"
    say "applied. backup at $BACKUP"
    exit 0
else
    err "write failed; $HOOK is untouched (backup at $BACKUP)"
    rm -f "$TMP"; exit 1
fi
