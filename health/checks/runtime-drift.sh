#!/bin/bash
# runtime-drift — versions of the tools you care about vs a known-compatible
# list. The tool set is data, not code:
#   $ACTIVITY_MESH_SYNC/compat-versions.txt — one "tool=version" per line,
#   where `tool` is a command on PATH that answers `--version`.
# Absent file → just record the observed versions as info (no drift concept).
#
# Example compat-versions.txt:
#   claude=2.1.0
#   codex=0.9.3

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

if [ ! -f "$COMPAT" ]; then
    am_emit "$NAME" 0 ok "no compat-versions.txt (declare tools to track there)"; exit 0
fi

drift=0; det=""; observed=""
while IFS='=' read -r tool ver; do
    [ -z "$tool" ] && continue
    case "$tool" in \#*) continue ;; esac   # allow comment lines
    cur=$(read_ver "$tool")
    observed="$observed ${tool}=${cur:-?}"
    if [ -n "$cur" ] && [ "$cur" != "$ver" ]; then
        drift=$((drift+1)); det="$det $tool: $ver→$cur"
    fi
done < "$COMPAT"

if [ "$drift" -eq 0 ]; then am_emit "$NAME" 1 ok "matches compat list:$observed"
else am_emit "$NAME" 2 warn "$drift drift(s):$det"
fi
exit 0
