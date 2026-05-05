#!/bin/bash
# launchd-jobs — expected activity-mesh launchd labels are loaded.
# Linux/win: skip with tier 0. Mac: compare to expected list.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=launchd-jobs

if [ "$(uname -s)" != "Darwin" ]; then
    am_emit "$NAME" 0 ok "non-mac, skipped"; exit 0
fi

EXPECTED=(com.activity-mesh.daemon com.activity-mesh.watcher com.activity-mesh.health com.activity-mesh.heartbeat)
loaded=$(launchctl list 2>/dev/null | awk '{print $3}')
missing=()
for label in "${EXPECTED[@]}"; do
    if ! printf '%s\n' "$loaded" | grep -qx "$label"; then
        missing+=("$label")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then am_emit "$NAME" 1 ok "all 4 jobs loaded"
elif [ "${#missing[@]}" -le 1 ]; then am_emit "$NAME" 2 warn "missing: ${missing[*]}"
else am_emit "$NAME" 3 fail "missing: ${missing[*]}"; fi
exit 0
