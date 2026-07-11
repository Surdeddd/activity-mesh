#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=launchd-jobs

if [ "$(uname -s)" != "Darwin" ]; then
    am_emit "$NAME" 0 ok "non-mac, skipped"; exit 0
fi

if [ -n "${ACTIVITY_MESH_EXPECTED_JOBS:-}" ]; then
    read -r -a EXPECTED <<< "$ACTIVITY_MESH_EXPECTED_JOBS"
else
    EXPECTED=(com.activity-mesh.daemon com.activity-mesh.watcher com.activity-mesh.health
              com.activity-mesh.heartbeat com.activity-mesh.compact com.activity-mesh.weekly-digest)
fi
loaded=$(launchctl list 2>/dev/null | awk '{print $3}')
missing=()
for label in "${EXPECTED[@]}"; do
    if ! printf '%s\n' "$loaded" | grep -qx "$label"; then
        missing+=("$label")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then am_emit "$NAME" 1 ok "all ${#EXPECTED[@]} jobs loaded"
elif [ "${#missing[@]}" -le 1 ]; then am_emit "$NAME" 2 warn "missing: ${missing[*]}"
else am_emit "$NAME" 3 fail "missing: ${missing[*]}"; fi
exit 0
