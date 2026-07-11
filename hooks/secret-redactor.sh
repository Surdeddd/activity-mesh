#!/bin/bash
set -uo pipefail

MODE="${ACTIVITY_MESH_REDACTOR_MODE:-closed}"
LOG="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}/redactor.log"

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true
}

BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    if [ "$MODE" = "open" ]; then
        log "warn: binary missing, FAIL-OPEN passthrough (ACTIVITY_MESH_REDACTOR_MODE=open)"
        echo "activity-mesh secret-redactor: binary missing — passing text through UNREDACTED (fail-open mode)" >&2
        /bin/cat
        exit 0
    fi
    log "error: binary missing, FAIL-CLOSED — refusing to pass unredacted text"
    echo "activity-mesh secret-redactor: activity-log binary not found — refusing to emit unredacted text (set ACTIVITY_MESH_REDACTOR_MODE=open to override)" >&2
    exit 1
fi

"$BIN" redact --stdin
rc=$?
if [ "$rc" -ne 0 ]; then
    log "error: redact exited $rc — FAIL-CLOSED"
    echo "activity-mesh secret-redactor: redact failed (exit $rc) — output suppressed" >&2
    exit 1
fi
exit 0
