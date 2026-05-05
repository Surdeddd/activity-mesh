#!/bin/bash
# secrets-bypass — entropy + regex re-scan over the last 30min of events.
# Catches what tier-1 missed at write time. Tier 4 critical on any hit.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=secrets-bypass
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing"; exit 0
fi

# Patterns NOT covered by tier-1 might still slip through if tier-1 was disabled.
PATS='sk-ant-[A-Za-z0-9_-]{32,}|sk-[A-Za-z0-9]{40,}|ghp_[A-Za-z0-9]{30,}|xox[abposr]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|AIza[A-Za-z0-9_-]{30,}|-----BEGIN [A-Z ]+PRIVATE KEY-----'

now=$(date +%s); cutoff=$(( now - 1800 ))
hits=0; sample=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if printf '%s' "$line" | grep -qE "$PATS"; then
            ts=$(printf '%s' "$line" | /usr/bin/jq -r '.ts // empty' 2>/dev/null) || ts=""
            ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
                      || date -u -d "$ts" +%s 2>/dev/null || echo 0)
            [ "$ts_epoch" -lt "$cutoff" ] && continue
            hits=$((hits+1))
            [ -z "$sample" ] && sample="$(basename "$f")"
        fi
    done < <(tail -n 200 "$f" 2>/dev/null)
done

if [ "$hits" -eq 0 ]; then am_emit "$NAME" 1 ok "no leaks in last 30min"
else am_emit "$NAME" 4 critical "$hits potential secrets in $sample (run RB-2 immediately)"; fi
exit 0
