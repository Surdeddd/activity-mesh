#!/bin/bash

# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
am_start
NAME=deploy-drift

SRC="${ACTIVITY_MESH_SRC_DIR:-$HOME/Projects/Personal/activity-mesh}"
DIST="$ACTIVITY_MESH_HOME/dist/current"

if [ ! -f "$SRC/VERSION" ]; then
    am_emit "$NAME" 0 ok "no local source checkout at $SRC — drift check skipped"; exit 0
fi
if [ ! -d "$DIST" ]; then
    am_emit "$NAME" 2 warn "dist/current missing at $DIST — nothing deployed yet"; exit 0
fi

dir_hash() {
    local d="$1"
    [ -d "$d" ] || { echo "missing"; return; }
    ( cd "$d" && find . -type f ! -name '.DS_Store' ! -name '*.bak-*' -print0 2>/dev/null \
        | sort -z | xargs -0 shasum -a 256 2>/dev/null ) | shasum -a 256 | awk '{print $1}'
}

src_ver=$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null)
dist_ver=$(tr -d '[:space:]' < "$DIST/VERSION" 2>/dev/null)

drifted=""
count=0
if [ "$src_ver" != "$dist_ver" ]; then
    drifted="VERSION($src_ver->$dist_ver)"
    count=$((count+1))
fi

for d in installers health registries configs hooks mcp; do
    [ -d "$SRC/$d" ] || continue
    s=$(dir_hash "$SRC/$d")
    t=$(dir_hash "$DIST/$d")
    if [ "$s" != "$t" ]; then
        drifted="$drifted $d"
        count=$((count+1))
    fi
done

if [ "$count" -eq 0 ]; then
    am_emit "$NAME" 1 ok "source matches dist/current (version $src_ver)"
elif [ "$count" -le 2 ] && [ "$src_ver" = "$dist_ver" ]; then
    am_emit "$NAME" 2 warn "$count area(s) drifted from source:$drifted — run installers/bootstrap.sh --local"
else
    am_emit "$NAME" 3 fail "$count area(s) drifted from source (src=$src_ver dist=$dist_ver):$drifted — run installers/bootstrap.sh --local"
fi
exit 0
