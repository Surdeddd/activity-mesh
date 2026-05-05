#!/bin/bash
# schema-drift — distinct kinds/scopes in last 24h vs registry whitelists.
# Tier 2 warn if drift; tier 3 fail if more than 5 unknown values.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=schema-drift
SYNC="$ACTIVITY_MESH_SYNC"

KINDS_FILE="$SYNC/kinds.yaml"
SCOPES_FILE="$SYNC/scopes.yaml"

if [ ! -f "$KINDS_FILE" ] && [ ! -f "$SCOPES_FILE" ]; then
    am_emit "$NAME" 0 ok "registry files absent (P7 not yet shipped)"; exit 0
fi

now=$(date +%s); cutoff=$(( now - 86400 ))
unk=0; sample=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ts=$(printf '%s' "$line" | /usr/bin/jq -r '.ts // empty' 2>/dev/null) || continue
        [ -z "$ts" ] && continue
        ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
                  || date -u -d "$ts" +%s 2>/dev/null || echo 0)
        [ "$ts_epoch" -lt "$cutoff" ] && continue
        kind=$(printf '%s' "$line" | /usr/bin/jq -r '.kind // empty' 2>/dev/null)
        scope=$(printf '%s' "$line" | /usr/bin/jq -r '.scope // empty' 2>/dev/null)
        if [ -f "$KINDS_FILE" ] && [ -n "$kind" ] && ! grep -qF "  - $kind" "$KINDS_FILE" 2>/dev/null; then
            unk=$((unk+1)); [ -z "$sample" ] && sample="kind=$kind"
        fi
        if [ -f "$SCOPES_FILE" ] && [ -n "$scope" ] && ! grep -qF "  - $scope" "$SCOPES_FILE" 2>/dev/null; then
            unk=$((unk+1)); [ -z "$sample" ] && sample="scope=$scope"
        fi
    done < <(tail -n 200 "$f" 2>/dev/null)
done

if [ "$unk" -eq 0 ]; then am_emit "$NAME" 1 ok "no drift"
elif [ "$unk" -lt 5 ]; then am_emit "$NAME" 2 warn "$unk unknown values (e.g. $sample)"
else am_emit "$NAME" 3 fail "$unk unknown values (e.g. $sample)"; fi
exit 0
