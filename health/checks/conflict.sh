#!/bin/bash
# conflict — find Syncthing conflict files in ~/Sync/activity/.
# Tier 4 critical if any conflicts found (means writer-collision or sync misconfig).

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=conflict
SYNC="$ACTIVITY_MESH_SYNC"

if [ ! -d "$SYNC" ]; then
    am_emit "$NAME" 2 warn "sync dir missing"; exit 0
fi

# Syncthing patterns: *.sync-conflict-* and ~syncthing~*.tmp
count=0; sample=""
while IFS= read -r f; do
    count=$((count+1))
    [ -z "$sample" ] && sample=$(basename "$f")
done < <(find "$SYNC" -maxdepth 2 -type f \( -name '*.sync-conflict-*' -o -name '~syncthing~*' -o -name '*.conflict' \) 2>/dev/null)

if [ "$count" -eq 0 ]; then
    am_emit "$NAME" 1 ok "no conflicts"
else
    am_emit "$NAME" 4 critical "found $count conflict files (e.g. $sample)"
fi
exit 0
