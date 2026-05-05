#!/bin/bash
# adoption-ratio — events per writer agent. Alert if 1 agent dominates >5:1.
# Uses temp-file aggregation (bash 3 compatible).

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=adoption-ratio
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then am_emit "$NAME" 2 warn "sync dir missing"; exit 0; fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    /usr/bin/jq -r '.agent // empty' < <(tail -n 500 "$f") 2>/dev/null
done >> "$TMP"

total=$(/usr/bin/wc -l < "$TMP" | tr -d ' ')
if [ "$total" -lt 10 ]; then
    am_emit "$NAME" 0 ok "insufficient data (total=$total)"; exit 0
fi

# top agent + count
top_line=$(/usr/bin/sort "$TMP" | /usr/bin/uniq -c | /usr/bin/sort -nr | head -1)
max=$(printf '%s' "$top_line" | awk '{print $1}')
max_a=$(printf '%s' "$top_line" | awk '{$1=""; sub(/^ /,""); print}')
n=$(/usr/bin/sort -u "$TMP" | /usr/bin/wc -l | tr -d ' ')

[ "$n" -le 1 ] && { am_emit "$NAME" 2 warn "only $n agent writing"; exit 0; }

others=$(( total - max )); [ "$others" -lt 1 ] && others=1
ratio=$(( max / others ))
if [ "$ratio" -gt 5 ]; then
    am_emit "$NAME" 2 warn "agent=$max_a dominates ${ratio}:1 (max=$max,others=$others)"
else
    am_emit "$NAME" 1 ok "balanced (top=$max_a ratio=${ratio}:1)"
fi
exit 0
