#!/bin/bash
# runtime-drift — versions of Claude Code, Codex, Hermes vs known-compatible.
# Compatible list: $ACTIVITY_MESH_SYNC/compat-versions.txt (one "tool=ver" per line).
# If file absent, just record current versions as info.

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=runtime-drift
COMPAT="$ACTIVITY_MESH_SYNC/compat-versions.txt"

read_ver() {
    cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
    fi
}
cc_ver=$(read_ver claude)
cx_ver=$(read_ver codex)
hm_ver=$(read_ver hermes)
got="claude=${cc_ver:-?},codex=${cx_ver:-?},hermes=${hm_ver:-?}"

if [ ! -f "$COMPAT" ]; then
    am_emit "$NAME" 0 ok "no compat-versions.txt; observed $got"; exit 0
fi

drift=0; det=""
while IFS='=' read -r tool ver; do
    [ -z "$tool" ] && continue
    case "$tool" in
        claude) cur="$cc_ver" ;;
        codex)  cur="$cx_ver" ;;
        hermes) cur="$hm_ver" ;;
        *) continue ;;
    esac
    if [ -n "$cur" ] && [ "$cur" != "$ver" ]; then
        drift=$((drift+1)); det="$det $tool: $ver→$cur"
    fi
done < "$COMPAT"

if [ "$drift" -eq 0 ]; then am_emit "$NAME" 1 ok "$got matches compat list"
else am_emit "$NAME" 2 warn "$drift drifts:$det"
fi
exit 0
