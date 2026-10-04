#!/bin/bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$HERE" ] || [ ! -r "$HERE/lib.sh" ]; then
    printf 'master.sh: cannot locate lib.sh (HERE=%s)\n' "$HERE" >&2
    exit 1
fi
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
CHECK_TIMEOUT_S="${ACTIVITY_MESH_CHECK_TIMEOUT_S:-120}"
case "$CHECK_TIMEOUT_S" in ''|*[!0-9]*) CHECK_TIMEOUT_S=120 ;; esac
CHECK_TIMEOUT_S=$(( 10#$CHECK_TIMEOUT_S ))
[ "$CHECK_TIMEOUT_S" -gt 0 ] || CHECK_TIMEOUT_S=120
ALERT_REPEAT_S="${ACTIVITY_MESH_ALERT_REPEAT_S:-86400}"
case "$ALERT_REPEAT_S" in ''|*[!0-9]*) ALERT_REPEAT_S=86400 ;; esac
ALERT_REPEAT_S=$(( 10#$ALERT_REPEAT_S ))
[ "$ALERT_REPEAT_S" -gt 0 ] || ALERT_REPEAT_S=86400
TMP_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

run_check() {
    local chk="$1" out="$2" err="$3" cpid wpid
    bash "$chk" >"$out" 2>"$err" &
    cpid=$!
    (
        spid=""
        trap '[ -n "$spid" ] && kill "$spid" 2>/dev/null; exit 0' TERM
        sleep "$CHECK_TIMEOUT_S" &
        spid=$!
        wait "$spid"
        : > "$out.timeout"
        kill -TERM "$cpid" 2>/dev/null
        sleep 2
        kill -KILL "$cpid" 2>/dev/null
    ) &
    wpid=$!
    wait "$cpid" 2>/dev/null
    kill -TERM "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    return 0
}

pids=()
for chk in "$CHECKS_DIR"/*.sh; do
    [ -f "$chk" ] || continue
    name=${chk##*/}; name=${name%.sh}
    run_check "$chk" "$TMP_DIR/$name.json" "$TMP_DIR/$name.err" &
    pids+=("$!")
done

for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" 2>/dev/null || true; done

NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(am_host)

results_json="["
first=1; ok=0; warn=0; fail=0; critical=0; max_tier=0
for chk in "$CHECKS_DIR"/*.sh; do
    [ -f "$chk" ] || continue
    name=${chk##*/}; name=${name%.sh}
    out="$TMP_DIR/$name.json"
    if [ -e "$out.timeout" ]; then
        line=$(printf '{"name":"%s","tier":2,"status":"warn","message":"timed out after %ss","duration_ms":%d}' \
            "$name" "$CHECK_TIMEOUT_S" $(( CHECK_TIMEOUT_S * 1000 )))
    elif [ ! -s "$out" ]; then
        line=$(printf '{"name":"%s","tier":3,"status":"fail","message":"check produced no output","duration_ms":0}' "$name")
    else
        line=$(head -1 "$out")
        if ! printf '%s' "$line" | "$AM_JQ" -e . >/dev/null 2>&1; then
            line=$(printf '{"name":"%s","tier":3,"status":"fail","message":"non-json output","duration_ms":0}' "$name")
        fi
    fi
    [ "$first" -eq 1 ] && first=0 || results_json="$results_json,"
    results_json="$results_json$line"
    tier=$(printf '%s' "$line" | "$AM_JQ" -r '.tier // 3' 2>/dev/null)
    case "$tier" in ''|*[!0-9]*) tier=3 ;; esac
    [ "$tier" -gt "$max_tier" ] && max_tier=$tier
    status=$(printf '%s' "$line" | "$AM_JQ" -r '.status // "fail"' 2>/dev/null)
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

if printf '%s' "$doc" | "$AM_JQ" -e . >/dev/null 2>&1; then
    if [ "$PRETTY" -eq 1 ]; then
        printf '%s\n' "$doc" | "$AM_JQ" .
    else
        printf '%s\n' "$doc"
    fi
else
    printf '{"error":"aggregation failed"}\n' >&2
    exit 0
fi

SNAP_DIR="$ACTIVITY_MESH_STATE"
mkdir -p "$SNAP_DIR" 2>/dev/null || true
printf '%s\n' "$doc" > "$SNAP_DIR/last-health.json" 2>/dev/null || true

LAST_ALERT="$ACTIVITY_MESH_STATE/health-last-alert"
if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$max_tier" -ge 2 ]; then
        failing=$(printf '%s' "$results_json" | "$AM_JQ" -r \
            '[.[] | select(.status != "ok") | "\(.name)=\(.status)"] | join(", ")' 2>/dev/null || true)
        sig=$(printf '%s' "$results_json" | "$AM_JQ" -r \
            '[.[] | select((.tier // 3) >= 2) | "\(.name)=\(.status)"] | join(", ")' 2>/dev/null || true)
        now=$(date +%s); prev_ts=0; prev_sig=""
        if [ -f "$LAST_ALERT" ]; then
            IFS=$'\t' read -r prev_ts prev_sig < "$LAST_ALERT" || true
            case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
        fi
        if [ "$sig" = "$prev_sig" ] && [ $(( now - prev_ts )) -lt "$ALERT_REPEAT_S" ]; then
            printf 'info: repeat alert suppressed (%s, first sent %ss ago)\n' "$sig" $(( now - prev_ts )) >&2
        else
            fmt=$(am_t 'activity-mesh: %d ok, %d warnings, %d failures, %d severe (tier %d, %s)\n%s' \
                'activity-mesh: в норме %d, предупреждений %d, отказов %d, критичных %d (уровень %d, %s)\n%s')
            # shellcheck disable=SC2059
            msg=$(printf "$fmt" "$ok" "$warn" "$fail" "$critical" "$max_tier" "$HOST" "$failing")
            severity=warn
            { [ "$fail" -gt 0 ] || [ "$critical" -gt 0 ]; } && severity=fail
            if am_notify "$msg" "$severity"; then
                printf '%s\t%s\n' "$now" "$sig" > "$LAST_ALERT" 2>/dev/null || true
                am_record_alert master "$severity"
            else
                printf 'warn: health alert undeliverable (no notify cmd, no telegram creds)\n' >&2
            fi
        fi
    else
        rm -f "$LAST_ALERT" 2>/dev/null || true
    fi
fi

exit 0
