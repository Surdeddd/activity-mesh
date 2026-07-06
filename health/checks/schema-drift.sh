#!/bin/bash
# schema-drift — distinct kinds/scopes in the last 24h vs the registry
# whitelists in the sync dir. Tier 2 warn if any drift; tier 3 fail if >5.
#
# The registries store entries as `- name: <value>` (core) and, for kinds,
# `<org>/<name>:` extension keys — NOT `- <value>`. Matching the wrong shape
# flagged every event (including registered kinds like `canary`) as unknown.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=schema-drift
SYNC="$ACTIVITY_MESH_SYNC"

KINDS_FILE="$SYNC/kinds.yaml"
SCOPES_FILE="$SYNC/scopes.yaml"

if [ ! -f "$KINDS_FILE" ] && [ ! -f "$SCOPES_FILE" ]; then
    am_emit "$NAME" 0 ok "registry files absent (publish kinds.yaml/scopes.yaml to the sync dir)"; exit 0
fi

# Build newline-delimited known-sets once.
known_kinds=""
if [ -f "$KINDS_FILE" ]; then
    core=$(grep -E '^[[:space:]]*-[[:space:]]+name:' "$KINDS_FILE" | sed -E 's/.*name:[[:space:]]*//; s/[[:space:]]*$//')
    ext=$(grep -E '^[[:space:]]+[A-Za-z0-9_]+/[A-Za-z0-9_]+:' "$KINDS_FILE" | sed -E 's/:.*//; s/^[[:space:]]*//')
    known_kinds=$(printf '%s\n%s\n' "$core" "$ext")
fi
known_scopes=""
if [ -f "$SCOPES_FILE" ]; then
    known_scopes=$(grep -E '^[[:space:]]*-[[:space:]]+name:' "$SCOPES_FILE" | sed -E 's/.*name:[[:space:]]*//; s/[[:space:]]*$//')
fi
is_known() { printf '%s\n' "$2" | grep -qxF "$1"; }

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
        if [ -f "$KINDS_FILE" ] && [ -n "$kind" ] && ! is_known "$kind" "$known_kinds"; then
            unk=$((unk+1)); [ -z "$sample" ] && sample="kind=$kind"
        fi
        if [ -f "$SCOPES_FILE" ] && [ -n "$scope" ] && ! is_known "$scope" "$known_scopes"; then
            unk=$((unk+1)); [ -z "$sample" ] && sample="scope=$scope"
        fi
    done < <(tail -n 200 "$f" 2>/dev/null)
done

if [ "$unk" -eq 0 ]; then am_emit "$NAME" 1 ok "no drift"
elif [ "$unk" -lt 5 ]; then am_emit "$NAME" 2 warn "$unk unknown values (e.g. $sample)"
else am_emit "$NAME" 3 fail "$unk unknown values (e.g. $sample)"; fi
exit 0
