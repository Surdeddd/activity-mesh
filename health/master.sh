#!/bin/bash
# master.sh — run all 19 health checks in parallel; aggregate single JSON document.
# Each check is required to:
#   1. exit 0 (any non-zero is itself a failure)
#   2. emit exactly one JSON line on stdout: {name,tier,status,message,duration_ms}
#
# Usage:
#   health/master.sh                  emit JSON to stdout, push to notify-maxim if tier ≥ 2
#   health/master.sh --dry-run        skip notify-maxim
#   health/master.sh --pretty         human-readable summary too
#
# Exit 0 always (orchestrator interprets via JSON).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DRY_RUN=0; PRETTY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --pretty)  PRETTY=1 ;;
    esac
done

CHECKS_DIR="$HERE/checks"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. dispatch all checks concurrently
pids=()
for chk in "$CHECKS_DIR"/*.sh; do
    [ -f "$chk" ] || continue
    name=$(basename "$chk" .sh)
    out="$TMP_DIR/$name.json"
    err="$TMP_DIR/$name.err"
    (
        # 30s hard cap per check — defend against hung greps
        if command -v gtimeout >/dev/null 2>&1; then
            gtimeout 30 bash "$chk" 2>"$err" > "$out"
        elif command -v timeout >/dev/null 2>&1; then
            timeout 30 bash "$chk" 2>"$err" > "$out"
        else
            bash "$chk" 2>"$err" > "$out"
        fi
    ) &
    pids+=($!)
done

for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

# 2. aggregate. malformed/missing → synthesize "fail" entry.
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(am_host)

results_json="["
first=1; ok=0; warn=0; fail=0; critical=0; max_tier=0
for chk in "$CHECKS_DIR"/*.sh; do
    [ -f "$chk" ] || continue
    name=$(basename "$chk" .sh)
    out="$TMP_DIR/$name.json"
    if [ ! -s "$out" ]; then
        line=$(printf '{"name":"%s","tier":3,"status":"fail","message":"check produced no output","duration_ms":0}' "$name")
    else
        line=$(head -1 "$out")
        if ! printf '%s' "$line" | /usr/bin/jq -e . >/dev/null 2>&1; then
            line=$(printf '{"name":"%s","tier":3,"status":"fail","message":"non-json output","duration_ms":0}' "$name")
        fi
    fi
    [ "$first" -eq 1 ] && first=0 || results_json="$results_json,"
    results_json="$results_json$line"
    tier=$(printf '%s' "$line" | /usr/bin/jq -r '.tier // 3' 2>/dev/null)
    case "$tier" in ''|*[!0-9]*) tier=3 ;; esac
    [ "$tier" -gt "$max_tier" ] && max_tier=$tier
    status=$(printf '%s' "$line" | /usr/bin/jq -r '.status // "fail"' 2>/dev/null)
    case "$status" in
        ok)       ok=$((ok+1)) ;;
        warn)     warn=$((warn+1)) ;;
        fail)     fail=$((fail+1)) ;;
        critical) critical=$((critical+1)) ;;
        *)        fail=$((fail+1)) ;;
    esac
done
results_json="$results_json]"

summary=$(printf '{"ok":%d,"warn":%d,"fail":%d,"critical":%d,"max_tier":%d}' \
    "$ok" "$warn" "$fail" "$critical" "$max_tier")

doc=$(printf '{"generated_at":"%s","host":"%s","checks":%s,"summary":%s}' \
    "$NOW_TS" "$HOST" "$results_json" "$summary")

# 3. validate + emit
if printf '%s' "$doc" | /usr/bin/jq -e . >/dev/null 2>&1; then
    if [ "$PRETTY" -eq 1 ]; then
        printf '%s\n' "$doc" | /usr/bin/jq .
    else
        printf '%s\n' "$doc"
    fi
else
    printf '{"error":"aggregation failed"}\n' >&2
    exit 0
fi

# 4. notify if any tier ≥ 2 (warn+). am_notify tries the configured
# notifier, then legacy notify-maxim, then direct Telegram — a missing
# notifier binary must never again mean weeks of silent red.
if [ "$max_tier" -ge 2 ] && [ "$DRY_RUN" -eq 0 ]; then
    failing=$(printf '%s' "$results_json" | /usr/bin/jq -r \
        '[.[] | select(.status != "ok") | "\(.name)=\(.status)"] | join(", ")' 2>/dev/null || true)
    msg=$(printf 'activity-mesh health: tier=%d ok=%d warn=%d fail=%d critical=%d (host=%s)\n%s' \
        "$max_tier" "$ok" "$warn" "$fail" "$critical" "$HOST" "$failing")
    if ! am_notify "$msg"; then
        printf 'warn: health alert undeliverable (no notify cmd, no telegram creds)\n' >&2
    fi
fi

# 5. snapshot for observability
SNAP_DIR="$ACTIVITY_MESH_STATE"
mkdir -p "$SNAP_DIR" 2>/dev/null || true
printf '%s\n' "$doc" > "$SNAP_DIR/last-health.json" 2>/dev/null || true

exit 0
