#!/bin/bash

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

known_kinds=""; have_kinds=0
if [ -f "$KINDS_FILE" ]; then
    have_kinds=1
    known_kinds=$(grep -E '^[[:space:]]*-[[:space:]]+name:' "$KINDS_FILE" | sed -E 's/.*name:[[:space:]]*//; s/[[:space:]]*$//')
fi
known_scopes=""; have_scopes=0
if [ -f "$SCOPES_FILE" ]; then
    have_scopes=1
    known_scopes=$(grep -E '^[[:space:]]*-[[:space:]]+name:' "$SCOPES_FILE" | sed -E 's/.*name:[[:space:]]*//; s/[[:space:]]*$//')
fi

cutoff=$(( $(date +%s) - 86400 ))
result=$(for f in "$SYNC"/events-*.jsonl; do [ -f "$f" ] && tail -n 2000 "$f"; echo; done 2>/dev/null \
    | "$AM_JQ" -rR --argjson cutoff "$cutoff" '
        fromjson? | select(type == "object")
        | select(((.ts // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) >= $cutoff)
        | "\(.kind // "")\t\(.scope // "")"' \
    | KNOWN_KINDS="$known_kinds" KNOWN_SCOPES="$known_scopes" awk -F'\t' -v hk="$have_kinds" -v hs="$have_scopes" '
        BEGIN {
            nk = split(ENVIRON["KNOWN_KINDS"], k, "\n"); for (i = 1; i <= nk; i++) K[k[i]] = 1
            ns = split(ENVIRON["KNOWN_SCOPES"], s, "\n"); for (i = 1; i <= ns; i++) S[s[i]] = 1
        }
        {
            if (hk && $1 != "" && !($1 in K) && index($1, "/") == 0) { u++; if (sample == "") sample = "kind=" $1 }
            sc = $2; root = sc; sub(/:.*/, "", root)
            if (hs && sc != "" && !(sc in S) && !(root in S)) { u++; if (sample == "") sample = "scope=" sc }
        }
        END { printf "%d %s\n", u + 0, sample }')
read -r unk sample <<< "${result:-0}"

if [ "$unk" -eq 0 ]; then am_emit "$NAME" 1 ok "no drift"
elif [ "$unk" -lt 5 ]; then am_emit "$NAME" 2 warn "$unk unknown values (e.g. $sample)"
else am_emit "$NAME" 3 fail "$unk unknown values (e.g. $sample)"; fi
exit 0
