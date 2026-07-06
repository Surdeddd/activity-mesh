#!/bin/bash
# token-budget — telemetry on average ambient tokens per session this week.
# Reads $ACTIVITY_MESH_STATE/tokens-* (the per-session counters the router
# writes — it moved out of /tmp; reading /tmp here reported "no telemetry"
# forever), aggregates last 100.
# Target ≤500 ambient. >500 fail, 350-500 warn, <350 ok.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=token-budget

shopt -s nullglob 2>/dev/null
files=("$ACTIVITY_MESH_STATE"/tokens-*)
shopt -u nullglob 2>/dev/null

if [ "${#files[@]}" -eq 0 ]; then
    am_emit "$NAME" 0 ok "no session telemetry yet"; exit 0
fi

sum=0; n=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) continue ;; esac
    sum=$(( sum + v )); n=$(( n + 1 ))
    [ "$n" -ge 100 ] && break
done

[ "$n" -eq 0 ] && { am_emit "$NAME" 0 ok "no usable counters"; exit 0; }
avg=$(( sum / n ))

if   [ "$avg" -gt 500 ]; then am_emit "$NAME" 3 fail "avg=$avg over 500 cap (n=$n)"
elif [ "$avg" -gt 350 ]; then am_emit "$NAME" 2 warn "avg=$avg approaching cap (n=$n)"
else am_emit "$NAME" 1 ok "avg=$avg/500 (n=$n)"
fi
exit 0
