#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=canary
SYNC="$ACTIVITY_MESH_SYNC"
STALE_S="${ACTIVITY_MESH_CANARY_STALE_S:-7200}"
host=$(am_host)
F="$SYNC/events-$host.jsonl"

if [ ! -f "$F" ]; then
    am_emit "$NAME" 2 warn "host shard $F missing"; exit 0
fi

now=$(date +%s)
awake=$(( now - $(am_last_wake) ))
stats=$(tail -n 2000 "$F" 2>/dev/null | "$AM_JQ" -nrR --argjson cutoff $(( now - 86400 )) '
    [inputs | fromjson? | select(type == "object" and .kind == "canary")
     | {t: ((.ts // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0),
        ok: ((.summary // "") | test("ok=1"))}]
    | (map(select(.t >= $cutoff))) as $day
    | "\($day | length) \($day | map(select(.ok | not)) | length) \(map(.t) | max // 0)"')
read -r count bad last <<< "${stats:-0 0 0}"

if [ "$last" -eq 0 ]; then
    am_emit "$NAME" 3 fail "no canary events in $F (writer/launchd issue)"
    exit 0
fi
age=$(( now - last ))
if [ "$age" -gt "$STALE_S" ] && [ "$awake" -gt "$STALE_S" ]; then
    am_emit "$NAME" 3 fail "last canary ${age}s ago, awake ${awake}s (writer/launchd issue)"
else
    am_emit "$NAME" 1 ok "last canary ${age}s ago; $count in 24h, $bad without a daemon answer"
fi
exit 0
