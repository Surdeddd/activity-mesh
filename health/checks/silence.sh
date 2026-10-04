#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start

NAME=silence
SYNC="$ACTIVITY_MESH_SYNC"
TH="${ACTIVITY_MESH_SILENCE_MAX_S:-43200}"
GRACE="${ACTIVITY_MESH_WAKE_GRACE_S:-1800}"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing: $SYNC"; exit 0
fi

now=$(date +%s)
since_wake=$(( now - $(am_last_wake) ))
worst_age=0; worst_host=""
offline_hosts="$(am_offline_hosts)"
offline_seen=""; pending=""

while IFS= read -r f; do
    base=${f##*/}; base=${base%.jsonl}; host=${base#events-}
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
    age=$(( now - mtime ))
    [ "$age" -gt "$TH" ] || continue
    if am_host_is_offline "$host" "$offline_hosts"; then
        offline_seen="$offline_seen $host($(( age / 3600 ))h)"
    elif [ "$since_wake" -lt "$GRACE" ]; then
        pending="$pending $host"
    elif [ "$age" -gt "$worst_age" ]; then
        worst_age=$age; worst_host=$host
    fi
done < <(am_shards)

if [ -n "$worst_host" ]; then
    am_emit "$NAME" 3 fail "host=$worst_host age=${worst_age}s threshold=${TH}s"
elif [ -n "$pending" ]; then
    am_emit "$NAME" 1 ok "$(am_t "woke ${since_wake}s ago, not judging yet:$pending" \
        "проснулись ${since_wake} с назад, молчание пока не оцениваю:$pending")"
elif [ -n "$offline_seen" ]; then
    am_emit "$NAME" 1 ok "$(am_t "owner-disabled hosts are silent:$offline_seen (re-enable: ben-engine online <host>)" \
        "молчат выключенные хосты:$offline_seen (вернуть — ben-engine online <хост>)")"
else
    am_emit "$NAME" 1 ok "all hosts fresh"
fi
exit 0
