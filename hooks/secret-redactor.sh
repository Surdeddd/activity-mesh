#!/bin/bash
# secret-redactor — pre-write redaction wrapper.
# Pipes stdin → activity-log redact --stdin → stdout.
# Idempotent: already-redacted text passes through unchanged.
# Used by other hooks (e.g. session-end-flush.sh) before persisting.
# Falls through (cat-pass) if Go binary missing — never silently drops data.

set -uo pipefail

BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
# Fallback: launchd/non-interactive shells often lack ~/.local/bin on PATH
# (parity with the read hooks — without this the redactor silently ran in
# pass-through mode under launchd, i.e. no redaction at all).
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    # Graceful degrade: pass through. Caller is responsible for awareness;
    # we log for diagnostic but never block the pipeline.
    LOG="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}/redactor.log"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] warn: binary missing, pass-through" \
        >> "$LOG" 2>/dev/null || true
    /bin/cat
    exit 0
fi

# Delegate to Go binary. It owns regex pack, entropy heuristic, and is idempotent.
"$BIN" redact --stdin
exit 0
