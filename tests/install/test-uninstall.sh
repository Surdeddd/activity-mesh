#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/amesh-uninstall-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sum_of() { cksum < "$1"; }

mkdir -p "$WORK/tmp" "$WORK/shim" "$WORK/shim-claude" "$WORK/tools"
SHIM="$WORK/shim"
SHIM_CLAUDE="$WORK/shim-claude"
TOOLS="$WORK/tools"
for c in launchctl systemctl loginctl sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/shim.log"\nexit 0\n' "$c" "$WORK" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
printf '#!/bin/sh\necho "claude $*" >> "%s/shim.log"\nexit 0\n' "$WORK" > "$SHIM_CLAUDE/claude"
chmod +x "$SHIM_CLAUDE/claude"
for t in jq python3; do
    tool_path="$(command -v "$t" 2>/dev/null || true)"
    if [ -n "$tool_path" ]; then ln -s "$tool_path" "$TOOLS/$t"; fi
done
BASE_PATH="/usr/bin:/bin"
RC=0
S=""
U_HOME=""
U_PREFIX=""
WITH_CLAUDE=1
NO_JQ=0

have() { [ -x "$TOOLS/$1" ]; }
toml_ok() {
    have python3 || return 0
    "$TOOLS/python3" -c 'import tomllib' 2>/dev/null || return 0
    "$TOOLS/python3" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1"
}
CODEX_BIN="$(command -v codex 2>/dev/null || true)"
codex_loads() {
    env -i HOME="$1" CODEX_HOME="$1/.codex" PATH="$(dirname "$CODEX_BIN"):/usr/bin:/bin" TMPDIR="$WORK/tmp" "$CODEX_BIN" mcp list > /dev/null 2>&1
}
codex_usable() {
    [ -n "$CODEX_BIN" ] || return 1
    mkdir -p "$WORK/codex-baseline/home/.codex"
    : > "$WORK/codex-baseline/home/.codex/config.toml"
    codex_loads "$WORK/codex-baseline/home"
}
run_path() {
    if [ "$NO_JQ" -eq 1 ]; then echo "$SHIM:$WORK/nojq"; return; fi
    if [ "$WITH_CLAUDE" -eq 1 ]; then echo "$SHIM:$SHIM_CLAUDE:$TOOLS:$BASE_PATH"; else echo "$SHIM:$TOOLS:$BASE_PATH"; fi
}

fs_id() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"; }
REAL_HOME_ID="$(fs_id "${HOME:-/nonexistent}" 2>/dev/null || echo none)"
WORK_CANON="$(cd -P "$WORK" && /bin/pwd -P)"
SKIPPED_SPELLINGS=0

new_sandbox() {
    local b
    S="$WORK/$1"
    U_HOME="$S/home"
    U_PREFIX="$S/prefix"
    mkdir -p "$U_HOME" "$U_PREFIX"
    case "$(cd -P "$U_HOME" && /bin/pwd -P)" in "$WORK_CANON"/*) ;; *) fail "sandbox $U_HOME is outside the test's temp dir" ;; esac
    [ "$(fs_id "$U_HOME")" != "$REAL_HOME_ID" ] || fail "sandbox HOME is the real HOME"
    for b in activity-log activity-watcher activity-mesh-daemon; do
        printf '#!/bin/sh\n' > "$U_PREFIX/$b"
        chmod +x "$U_PREFIX/$b"
    done
}

fake_store() {
    mkdir -p "$1/dist/1.0.0/hooks" "$1/dist/1.0.0/mcp" "$2"
    ln -s 1.0.0 "$1/dist/current"
    : > "$1/dist/1.0.0/mcp/server.mjs"
    printf 'idx\n' > "$1/index.db"
    printf 'log\n' > "$2/health.log"
}

uninstall_run() {
    local out="$1"; shift
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    set +e
    env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" ${envs[@]+"${envs[@]}"} \
        bash "$REPO_ROOT/installers/uninstall.sh" "$@" > "$out" 2>&1
    RC=$?
    set -e
}

test_default_dirs() {
    echo "== defaults are unchanged without the env vars =="
    new_sandbox default
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.config/activity-mesh"
    printf 'cfg\n' > "$U_HOME/.config/activity-mesh/watcher.yaml"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    [ ! -e "$U_HOME/.local/share/activity-mesh/dist" ] || fail "dist under the default store was not removed"
    [ -f "$U_HOME/.local/share/activity-mesh/index.db" ] || fail "index.db was removed without --purge"
    [ -f "$U_HOME/.local/state/activity-mesh/health.log" ] || fail "state was removed without --purge"
    [ ! -e "$U_PREFIX/activity-log" ] && [ ! -e "$U_PREFIX/activity-watcher" ] && [ ! -e "$U_PREFIX/activity-mesh-daemon" ] \
        || fail "binaries were not removed from the prefix"
    uninstall_run "$S/out-purge.txt" -- --purge
    [ "$RC" -eq 0 ] || fail "--purge exited $RC"
    [ ! -e "$U_HOME/.local/share/activity-mesh" ] && [ ! -e "$U_HOME/.local/state/activity-mesh" ] && [ ! -e "$U_HOME/.config/activity-mesh" ] \
        || fail "--purge left store, state or config behind"
    pass "without env vars the default store, state and config dirs are used"
}

test_env_dirs() {
    echo "== ACTIVITY_MESH_HOME / ACTIVITY_MESH_STATE steer uninstall like bootstrap =="
    new_sandbox env
    fake_store "$S/env-store" "$S/env-state"
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    uninstall_run "$S/out.txt" ACTIVITY_MESH_HOME="$S/env-store" ACTIVITY_MESH_STATE="$S/env-state" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    [ ! -e "$S/env-store/dist" ] || fail "dist under ACTIVITY_MESH_HOME was not removed"
    [ -f "$S/env-store/index.db" ] && [ -f "$S/env-state/health.log" ] || fail "data under the env dirs was removed without --purge"
    [ -d "$U_HOME/.local/share/activity-mesh/dist" ] || fail "the default store was touched although ACTIVITY_MESH_HOME is set"
    grep -qF "$S/env-store" "$S/out.txt" || fail "the output does not name the store dir in use: $(cat "$S/out.txt")"

    uninstall_run "$S/out-purge.txt" ACTIVITY_MESH_HOME="$S/env-store" ACTIVITY_MESH_STATE="$S/env-state" -- --purge
    [ "$RC" -eq 0 ] || fail "--purge exited $RC"
    [ ! -e "$S/env-store" ] && [ ! -e "$S/env-state" ] || fail "--purge left the env store or state behind"
    [ -f "$U_HOME/.local/share/activity-mesh/index.db" ] && [ -f "$U_HOME/.local/state/activity-mesh/health.log" ] \
        || fail "--purge removed the default dirs although the env vars point elsewhere"
    pass "the env dirs are the ones removed and purged; the default dirs stay"
}

expect_refused() {
    local name="$1" value="$2" sentinel_before
    shift 2
    sentinel_before="$(sum_of "$U_HOME/sentinel.txt")"
    uninstall_run "$S/out-refused.txt" "$name=$value" ${@+"$@"} -- --purge --dry-run
    [ "$RC" -ne 0 ] || { cat "$S/out-refused.txt" >&2; fail "$name=$value must be refused"; }
    grep -q "$name" "$S/out-refused.txt" || fail "the refusal of $name=$value does not name the variable: $(cat "$S/out-refused.txt")"
    if grep -q 'DRY' "$S/out-refused.txt"; then fail "$name=$value was refused only after the plan started: $(cat "$S/out-refused.txt")"; fi
    [ -d "$U_HOME/dist" ] && [ "$(sum_of "$U_HOME/sentinel.txt")" = "$sentinel_before" ] || fail "HOME was modified by $name=$value"
    [ -e "$U_PREFIX/activity-log" ] || fail "binaries were removed before the refusal of $name=$value"
}

expect_refused_alias() {
    local name="$1" value="$2" target="$3"
    if [ "$(fs_id "$value" 2>/dev/null)" != "$(fs_id "$target")" ]; then
        SKIPPED_SPELLINGS=$((SKIPPED_SPELLINGS + 1))
        return 0
    fi
    expect_refused "$name" "$value"
}

test_unsafe_dirs() {
    local v homes state_values tilde='~' nl=$'\n' canon_home upper_home upper_parent
    echo "== a store or state dir that is, or would take, HOME / the sync dir / / with it is refused =="
    new_sandbox unsafe
    printf 'keep\n' > "$U_HOME/sentinel.txt"
    mkdir -p "$U_HOME/dist" "$S/other" "$U_HOME/.local/share" "$U_HOME/.local/state" "$U_HOME/.config" "$U_HOME/Sync/activity" "$U_HOME/Documents"
    printf 'precious\n' > "$U_HOME/Documents/thesis.txt"
    printf 'x\n' > "$U_HOME/afile"
    ln -s "$U_HOME" "$S/homelink"
    ln -s loop "$S/loop"
    homes=(
        "$U_HOME" "$U_HOME/" "$U_HOME//" "$U_HOME/." "$U_HOME/./" "$S/other/../home" "$S/homelink" "$S/homelink/"
        / // /. /.. "$S" "$U_HOME/.."
        "$U_HOME/.local/share" "$U_HOME/.local" "$U_HOME/.config" "$U_HOME/Sync" "$U_HOME/Sync/activity" "$U_HOME/Sync/activity/"
        relative-dir ./relative-dir .. "$tilde" "$tilde/activity-mesh"
    )
    state_values=(
        / "$U_HOME//" "$S/homelink/" "$U_HOME/.local/state" "$U_HOME/Sync/activity" "$U_HOME/.." relative-state "$tilde"
    )
    for v in "${homes[@]}"; do
        expect_refused ACTIVITY_MESH_HOME "$v"
    done
    for v in "${state_values[@]}"; do
        expect_refused ACTIVITY_MESH_STATE "$v"
    done
    pass "HOME, its parents and symlinks to it, the sync dir and its parents, the XDG parents of the default dirs, / and relative values are all refused, in every spelling, before anything is planned"

    canon_home="$(cd -P "$U_HOME" && /bin/pwd -P)"
    upper_home="$(printf '%s' "$U_HOME" | tr 'a-z' 'A-Z')"
    upper_parent="$(dirname "$S")/$(basename "$S" | tr 'a-z' 'A-Z')"
    SKIPPED_SPELLINGS=0
    for v in "$S/HOME" "$S/HOME/" "$S/Home/." "$upper_home" "$S/HOME/../HOME"; do
        expect_refused_alias ACTIVITY_MESH_HOME "$v" "$U_HOME"
    done
    expect_refused_alias ACTIVITY_MESH_STATE "$S/HOME" "$U_HOME"
    expect_refused_alias ACTIVITY_MESH_HOME "$upper_parent" "$S"
    expect_refused_alias ACTIVITY_MESH_HOME "$U_HOME/SYNC/ACTIVITY" "$U_HOME/Sync/activity"
    expect_refused_alias ACTIVITY_MESH_HOME "$U_HOME/SYNC" "$U_HOME/Sync"
    expect_refused_alias ACTIVITY_MESH_HOME "$U_HOME/.LOCAL/SHARE" "$U_HOME/.local/share"
    expect_refused_alias ACTIVITY_MESH_STATE "$U_HOME/.LOCAL/STATE" "$U_HOME/.local/state"
    if [ -d /System/Volumes/Data ]; then
        expect_refused_alias ACTIVITY_MESH_HOME "/System/Volumes/Data$canon_home" "$U_HOME"
        expect_refused_alias ACTIVITY_MESH_STATE "/System/Volumes/Data$canon_home/" "$U_HOME"
        expect_refused_alias ACTIVITY_MESH_HOME "/System/Volumes/Data$(dirname "$canon_home")" "$S"
        expect_refused_alias ACTIVITY_MESH_HOME "/System/Volumes/Data$canon_home/.local/share" "$U_HOME/.local/share"
    fi
    case "$canon_home" in
        /private/*) expect_refused_alias ACTIVITY_MESH_HOME "/PRIVATE${canon_home#/private}" "$U_HOME" ;;
    esac
    if [ "$SKIPPED_SPELLINGS" -gt 0 ]; then
        echo "SKIP: $SKIPPED_SPELLINGS case or firmlink spellings do not alias the same directory on this filesystem"
    else
        pass "case variants and firmlink spellings of HOME, its parent, the sync dir and the XDG parents are refused (same inode, different name)"
    fi

    for v in "$U_HOME${nl}/Documents" "$U_HOME/Documents$nl" "$S${nl}/home" "$U_HOME/Documents${nl}/.."; do
        expect_refused ACTIVITY_MESH_HOME "$v"
        expect_refused ACTIVITY_MESH_STATE "$v"
    done
    [ -f "$U_HOME/Documents/thesis.txt" ] || fail "a value with a newline in it reached the files"
    pass "a value with a newline is refused instead of being retargeted by command substitution"

    for v in "$U_HOME/nope/.." "$U_HOME/nope/../.." "$S/loop/.." "$U_HOME/afile/.." "$U_HOME/nope/./.."; do
        expect_refused ACTIVITY_MESH_HOME "$v"
        expect_refused ACTIVITY_MESH_STATE "$v"
    done
    expect_refused ACTIVITY_MESH_HOME "$U_HOME/Documents/.."
    pass "a path that uses . or .. after something that does not exist cannot be resolved and is refused"

    ln -s "$U_HOME" "$U_HOME/.config/activity-mesh"
    uninstall_run "$S/out-cfg.txt" -- --purge --dry-run
    rm -f "$U_HOME/.config/activity-mesh"
    [ "$RC" -ne 0 ] || fail "a config dir that is a symlink to HOME must be refused"
    grep -q 'CONFIG_DIR' "$S/out-cfg.txt" || fail "the refusal does not name the config dir: $(cat "$S/out-cfg.txt")"
    if grep -q 'DRY' "$S/out-cfg.txt"; then fail "the plan started although the config dir points at HOME: $(cat "$S/out-cfg.txt")"; fi
    pass "a config dir that points at HOME is refused as well"

    uninstall_run "$S/out-ok.txt" ACTIVITY_MESH_HOME="$S/not-created-yet" ACTIVITY_MESH_STATE="$S/not-created-either" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-ok.txt" >&2; fail "a dedicated directory that does not exist yet was refused"; }
    pass "a dedicated directory is not refused, whether or not it exists yet"
}

write_config() {
    mkdir -p "$1"
    printf '{\n  "sync_dir": "%s",\n  "store_dir": "%s"\n}\n' "$2" "$1" > "$1/config.json"
}

test_sync_protection() {
    local default_store tilde='~'
    echo "== every sync dir is protected, whichever of env, config.json or the default names it =="
    new_sandbox syncs
    default_store="$U_HOME/.local/share/activity-mesh"
    printf 'keep\n' > "$U_HOME/sentinel.txt"
    mkdir -p "$U_HOME/dist" "$U_HOME/Dropbox/activity" "$U_HOME/Dropbox/photos" "$U_HOME/Elsewhere/sync" "$S/custom-store"
    printf 'ev\n' > "$U_HOME/Dropbox/activity/events.jsonl"

    write_config "$default_store" "$U_HOME/Dropbox/activity"
    expect_refused ACTIVITY_MESH_HOME "$U_HOME/Dropbox"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Dropbox/activity"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Dropbox/activity/"
    uninstall_run "$S/out.txt" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "a plain --purge --dry-run exited $RC"; }
    grep -qF "$U_HOME/Dropbox/activity alone" "$S/out.txt" || fail "the message does not name the sync dir that config.json sets: $(grep -i alone "$S/out.txt")"
    if grep -qF "Sync/activity alone" "$S/out.txt"; then fail "the message names the default sync dir although config.json sets another"; fi
    pass "the sync_dir of the default store's config.json is protected and named"

    write_config "$S/custom-store" "$U_HOME/Elsewhere/sync"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Elsewhere" ACTIVITY_MESH_HOME="$S/custom-store"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Elsewhere/sync" ACTIVITY_MESH_HOME="$S/custom-store"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Dropbox/activity"
    uninstall_run "$S/out-c.txt" ACTIVITY_MESH_HOME="$S/custom-store" -- --purge --dry-run
    grep -qF "$U_HOME/Elsewhere/sync alone" "$S/out-c.txt" || fail "the message does not name the sync dir of the given store: $(grep -i alone "$S/out-c.txt")"
    pass "the sync_dir of the store you name is protected too, next to the default store's"

    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Elsewhere" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Dropbox/activity" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync"
    uninstall_run "$S/out-e.txt" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync" -- --purge --dry-run
    grep -qF "$U_HOME/Elsewhere/sync alone" "$S/out-e.txt" || fail "the message does not name ACTIVITY_MESH_SYNC: $(grep -i alone "$S/out-e.txt")"
    pass "ACTIVITY_MESH_SYNC wins in the message, and every other sync dir stays protected"

    mkdir -p "$U_HOME/Elsewhere/sync/inner"
    : > "$U_HOME/Elsewhere/sync/inner/index.db"
    : > "$U_HOME/Elsewhere/sync/inner/health.log"
    expect_refused_with "is inside the sync dir" ACTIVITY_MESH_HOME "$U_HOME/Elsewhere/sync/inner" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync"
    expect_refused_with "is inside the sync dir" ACTIVITY_MESH_STATE "$U_HOME/Elsewhere/sync/inner" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync"
    pass "a store or state dir that sits inside a sync dir is refused, even when it looks like activity-mesh's own"

    mkdir -p "$U_HOME/R&D/activity"
    printf '{"sync_dir": "%s/R\\u0026D/activity"}\n' "$U_HOME" > "$default_store/config.json"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/R&D"
    printf '{"sync_dir": "%s/a\\tb"}\n' "$U_HOME" > "$default_store/config.json"
    uninstall_run "$S/out-bad.txt" -- --purge --dry-run
    [ "$RC" -ne 0 ] || fail "an undecodable sync_dir must stop the uninstall"
    grep -q 'ACTIVITY_MESH_SYNC' "$S/out-bad.txt" || fail "no hint to set ACTIVITY_MESH_SYNC: $(cat "$S/out-bad.txt")"
    if grep -q 'DRY' "$S/out-bad.txt"; then fail "the plan started although a sync_dir could not be decoded"; fi
    uninstall_run "$S/out-bad2.txt" ACTIVITY_MESH_SYNC="$U_HOME/Elsewhere/sync" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-bad2.txt" >&2; fail "ACTIVITY_MESH_SYNC must let an undecodable config.json through, got $RC"; }
    pass "JSON escapes in sync_dir are decoded; an undecodable one stops the uninstall unless ACTIVITY_MESH_SYNC says where the sync dir is"

    printf '{"sync_dir": "~/Dropbox/activity"}\n' > "$default_store/config.json"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Dropbox/activity"
    uninstall_run "$S/out-tilde.txt" -- --purge --dry-run
    grep -qF "$U_HOME/Dropbox/activity alone" "$S/out-tilde.txt" || fail "a ~ in sync_dir was not expanded: $(grep -i alone "$S/out-tilde.txt")"
    uninstall_run "$S/out-tilde-env.txt" ACTIVITY_MESH_SYNC="$tilde/Elsewhere/sync" -- --purge --dry-run
    grep -qF "$U_HOME/Elsewhere/sync alone" "$S/out-tilde-env.txt" || fail "a ~ in ACTIVITY_MESH_SYNC was not expanded: $(grep -i alone "$S/out-tilde-env.txt")"
    printf '{"sync_dir": "rel/dir"}\n' > "$default_store/config.json"
    uninstall_run "$S/out-rel.txt" -- --purge --dry-run
    grep -qF "/rel/dir alone" "$S/out-rel.txt" || fail "a relative sync_dir was not made absolute: $(grep -i alone "$S/out-rel.txt")"
    pass "a ~ or a relative path in sync_dir or ACTIVITY_MESH_SYNC is read the way the CLI reads it"

    rm -f "$default_store/config.json"
    mkdir -p "$U_HOME/Sync"
    ln -s "$U_HOME/Dropbox/activity" "$U_HOME/Sync/activity"
    expect_refused ACTIVITY_MESH_HOME "$U_HOME/Sync"
    expect_refused ACTIVITY_MESH_HOME "$U_HOME/Dropbox"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Sync/activity"
    pass "a symlinked sync dir protects its own parents and the parents of what it points to"
}

test_store_spellings() {
    local real canon settings
    echo "== trailing slashes and symlinked stores still find and remove their registrations =="
    if ! have jq; then skip "jq not found"; return 0; fi
    new_sandbox spell
    real="$S/real-store"
    fake_store "$real" "$S/real-state"
    ln -s "$real" "$S/store-link"
    canon="$(cd -P "$real" && pwd -P)"
    mkdir -p "$U_HOME/.claude"
    settings="$U_HOME/.claude/settings.json"
    cat > "$settings" <<JSON
{"hooks": {"SessionStart": [
  {"matcher": "", "hooks": [{"type": "command", "command": "$S/store-link/dist/current/hooks/via-link.sh"}]},
  {"matcher": "", "hooks": [{"type": "command", "command": "$canon/dist/1.0.0/hooks/via-canonical.sh"}]},
  {"matcher": "x", "hooks": [{"type": "command", "command": "/opt/keep.sh"}]}
]}}
JSON
    uninstall_run "$S/out.txt" ACTIVITY_MESH_HOME="$S/store-link//" ACTIVITY_MESH_STATE="$S/real-state/" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    "$TOOLS/jq" -e '[.hooks.SessionStart[].hooks[].command] == ["/opt/keep.sh"]' "$settings" >/dev/null \
        || fail "hooks registered through the symlink or the canonical path survived: $(cat "$settings")"
    [ ! -e "$real/dist" ] || fail "dist behind the symlinked store was not removed"
    [ -f "$real/index.db" ] && [ -f "$S/real-state/health.log" ] || fail "data was removed without --purge"
    pass "a store given with trailing slashes or through a symlink is matched under both spellings"

    ln -s "$S/real-state" "$S/state-link"
    uninstall_run "$S/out-purge.txt" ACTIVITY_MESH_HOME="$S/store-link/" ACTIVITY_MESH_STATE="$S/state-link" -- --purge
    [ "$RC" -eq 0 ] || { cat "$S/out-purge.txt" >&2; fail "--purge exited $RC"; }
    [ ! -e "$real" ] && [ ! -e "$S/real-state" ] || fail "--purge left the symlinked store or the state dir behind"
    [ ! -L "$S/store-link" ] && [ ! -L "$S/state-link" ] || fail "--purge left a dangling link behind, which makes the next bootstrap fail at mkdir"
    [ -d "$U_HOME" ] || fail "HOME disappeared"
    mkdir -p "$S/store-link" "$S/state-link"
    pass "--purge removes the directory a symlinked store or state dir points to, and the link as well"
}

test_odd_paths() {
    echo "== a store path with shell metacharacters removes exactly that path =="
    new_sandbox odd
    mkdir -p "$S/with space"
    fake_store "$S/with space/st\$ore" "$S/with space/state"
    fake_store "$S/with space/st" "$S/with space/other-state"
    uninstall_run "$S/out.txt" ACTIVITY_MESH_HOME="$S/with space/st\$ore" ACTIVITY_MESH_STATE="$S/with space/state" -- --purge
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    [ ! -e "$S/with space/st\$ore" ] || fail "the store with a \$ in its name survived"
    [ -d "$S/with space/st/dist" ] && [ -f "$S/with space/st/index.db" ] || fail "a neighbouring directory was removed instead (shell expansion of the path)"
    pass "paths holding spaces and \$ are removed verbatim"
}

test_dry_run() {
    echo "== --dry-run changes nothing =="
    new_sandbox dry
    fake_store "$S/env-store" "$S/env-state"
    uninstall_run "$S/out.txt" ACTIVITY_MESH_HOME="$S/env-store" ACTIVITY_MESH_STATE="$S/env-state" -- --purge --dry-run
    [ "$RC" -eq 0 ] || fail "--dry-run exited $RC"
    [ -d "$S/env-store/dist" ] && [ -f "$S/env-store/index.db" ] && [ -f "$S/env-state/health.log" ] || fail "--dry-run removed data"
    [ -e "$U_PREFIX/activity-log" ] || fail "--dry-run removed a binary"
    grep -q 'DRY' "$S/out.txt" || fail "--dry-run printed no plan"
    pass "--dry-run prints the plan and removes nothing"
}

make_nojq_path() {
    local c p
    mkdir -p "$WORK/nojq"
    for c in bash uname id dirname rm mktemp cp cmp date grep readlink stat mv chmod cat sed tr wc head; do
        p="$(command -v "$c" 2>/dev/null || true)"
        if [ -n "$p" ] && [ ! -e "$WORK/nojq/$c" ]; then ln -s "$p" "$WORK/nojq/$c"; fi
    done
}

test_alternate_prefix() {
    local b
    echo "== binaries are removed from ~/.local/bin as well as --prefix =="
    new_sandbox altprefix
    mkdir -p "$U_HOME/.local/bin"
    for b in activity-log activity-watcher activity-mesh-daemon other-tool; do
        printf '#!/bin/sh\n' > "$U_HOME/.local/bin/$b"
        chmod +x "$U_HOME/.local/bin/$b"
    done
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    for b in activity-log activity-watcher activity-mesh-daemon; do
        [ ! -e "$U_HOME/.local/bin/$b" ] || fail "$b was left in ~/.local/bin"
        [ ! -e "$U_PREFIX/$b" ] || fail "$b was left in the prefix"
    done
    [ -e "$U_HOME/.local/bin/other-tool" ] || fail "an unrelated file in ~/.local/bin was removed"
    pass "a previous ~/.local/bin install is cleaned up and unrelated files stay"

    new_sandbox sameprefix
    U_PREFIX="$U_HOME/.local/bin"
    mkdir -p "$U_PREFIX"
    for b in activity-log activity-watcher activity-mesh-daemon; do
        printf '#!/bin/sh\n' > "$U_PREFIX/$b"
        chmod +x "$U_PREFIX/$b"
    done
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC when the prefix is ~/.local/bin"; }
    [ ! -e "$U_PREFIX/activity-log" ] && [ ! -e "$U_PREFIX/activity-watcher" ] && [ ! -e "$U_PREFIX/activity-mesh-daemon" ] \
        || fail "binaries were left in ~/.local/bin used as the prefix"
    pass "--prefix ~/.local/bin works"
}

test_claude_hooks() {
    local store settings before
    echo "== Claude Code hooks pointing into dist are removed, the rest stays =="
    if ! have jq; then skip "jq not found"; return 0; fi
    new_sandbox hooks
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$S/dotfiles" "$U_HOME/.claude"
    settings="$S/dotfiles/settings.json"
    cat > "$settings" <<JSON
{
  "theme": "dark",
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/session-start-digest.sh"}]},
      {"matcher": "x", "hooks": [{"type": "command", "command": "/opt/keep-start.sh"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "$store/dist/1.0.0/hooks/user-prompt-router.sh"},
        {"type": "command", "command": "/opt/keep-prompt.sh"}
      ]}
    ],
    "PreCompact": [
      {"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/only-ours.sh"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/repo/hooks/stop.sh"}]}
    ]
  }
}
JSON
    chmod 600 "$settings"
    ln -s "$settings" "$U_HOME/.claude/settings.json"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    [ -L "$U_HOME/.claude/settings.json" ] || fail "the settings.json symlink was replaced by a regular file"
    "$TOOLS/jq" -e '.theme == "dark"' "$settings" >/dev/null || fail "unrelated settings were lost: $(cat "$settings")"
    "$TOOLS/jq" -e '[.hooks.SessionStart[].hooks[].command] == ["/opt/keep-start.sh"]' "$settings" >/dev/null \
        || fail "SessionStart after uninstall: $("$TOOLS/jq" -c .hooks.SessionStart "$settings")"
    "$TOOLS/jq" -e '[.hooks.UserPromptSubmit[].hooks[].command] == ["/opt/keep-prompt.sh"]' "$settings" >/dev/null \
        || fail "UserPromptSubmit after uninstall: $("$TOOLS/jq" -c .hooks.UserPromptSubmit "$settings")"
    "$TOOLS/jq" -e '.hooks | has("PreCompact") | not' "$settings" >/dev/null || fail "an event left empty by the uninstall was kept"
    "$TOOLS/jq" -e '[.hooks.Stop[].hooks[].command] == ["/repo/hooks/stop.sh"]' "$settings" >/dev/null || fail "a hook outside dist was touched"
    if grep -qF "$store/dist" "$settings"; then fail "a reference to dist survived: $(cat "$settings")"; fi
    [ "$(mode_of "$settings")" = "600" ] || fail "settings.json mode changed to $(mode_of "$settings")"
    [ -n "$(find "$U_HOME/.claude" -name 'settings.json.bak-*')" ] || fail "no backup of settings.json"
    [ -z "$(find "$S/dotfiles" -name 'settings.json.*')" ] || fail "temp files left next to settings.json"
    [ ! -e "$store/dist" ] || fail "dist was not removed"
    pass "hooks under dist are removed from a symlinked settings.json; others, mode and link stay"

    new_sandbox hooks-only-ours
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.claude"
    settings="$U_HOME/.claude/settings.json"
    cat > "$settings" <<JSON
{"theme": "dark", "hooks": {
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/session-start-digest.sh"}]}],
  "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/user-prompt-router.sh"}]}]
}}
JSON
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    "$TOOLS/jq" -e '. == {"theme": "dark"}' "$settings" >/dev/null || fail "an emptied hooks object was kept: $(cat "$settings")"
    pass "when every hook was ours the hooks key goes away and the other settings stay"

    new_sandbox hooks-repo
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.claude"
    settings="$U_HOME/.claude/settings.json"
    cat > "$settings" <<JSON
{"note": "$store/dist/readme", "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "/repo/hooks/session-start-digest.sh"}]}]}}
JSON
    before="$(sum_of "$settings")"
    uninstall_run "$S/out.txt" CLAUDE_SETTINGS="$settings" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    [ "$(sum_of "$settings")" = "$before" ] || fail "settings.json was rewritten although no hook points into dist"
    [ -z "$(find "$U_HOME/.claude" -name 'settings.json.bak-*')" ] || fail "a backup was written although nothing changed"
    pass "hooks that point at a repo checkout are left alone, even when dist is mentioned elsewhere"
}

test_claude_mcp() {
    local store before cj
    echo "== the Claude MCP registration pointing into dist is removed =="
    if ! have jq; then skip "jq not found"; return 0; fi
    new_sandbox mcp-cli
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    cj="$U_HOME/.claude.json"
    cat > "$cj" <<JSON
{"mcpServers": {"activity-mesh": {"command": "node", "args": ["$store/dist/current/mcp/server.mjs"]}, "other": {"command": "o"}}}
JSON
    before="$(sum_of "$cj")"
    : > "$WORK/shim.log"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    grep -qxF "claude mcp remove activity-mesh --scope user" "$WORK/shim.log" || fail "claude mcp remove was not called: $(cat "$WORK/shim.log")"
    [ "$(sum_of "$cj")" = "$before" ] || fail "the user-scope claude.json was edited directly although the claude CLI is available"
    pass "with the claude CLI the registration is removed through claude mcp remove"

    new_sandbox mcp-repo
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    cj="$U_HOME/.claude.json"
    printf '%s\n' '{"mcpServers":{"activity-mesh":{"command":"node","args":["/repo/mcp/server.mjs"]}}}' > "$cj"
    before="$(sum_of "$cj")"
    : > "$WORK/shim.log"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    if grep -q 'mcp remove' "$WORK/shim.log"; then fail "claude mcp remove ran for a registration that points at a repo checkout"; fi
    [ "$(sum_of "$cj")" = "$before" ] || fail "the user-scope claude.json changed"
    pass "a registration that points at a repo checkout is left alone"

    WITH_CLAUDE=0
    new_sandbox mcp-jq
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$S/dotfiles"
    cat > "$S/dotfiles/claude.json" <<JSON
{"other": 1, "mcpServers": {"activity-mesh": {"command": "node", "args": ["$store/dist/current/mcp/server.mjs"]}, "other": {"command": "o"}}}
JSON
    chmod 600 "$S/dotfiles/claude.json"
    ln -s "$S/dotfiles/claude.json" "$U_HOME/.claude.json"
    uninstall_run "$S/out.txt" --
    WITH_CLAUDE=1
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC without the claude CLI"; }
    [ -L "$U_HOME/.claude.json" ] || fail "the ~/.claude.json symlink was replaced by a regular file"
    "$TOOLS/jq" -e '(.mcpServers | has("activity-mesh") | not) and .mcpServers.other.command == "o" and .other == 1' "$S/dotfiles/claude.json" >/dev/null \
        || fail "the jq fallback did not remove exactly the activity-mesh entry: $(cat "$S/dotfiles/claude.json")"
    [ "$(mode_of "$S/dotfiles/claude.json")" = "600" ] || fail "mode changed to $(mode_of "$S/dotfiles/claude.json")"
    [ -n "$(find "$U_HOME" -maxdepth 1 -name '.claude.json.bak-*')" ] || fail "no backup of ~/.claude.json"
    pass "without the claude CLI the entry is removed with jq through the symlink"
}

test_codex_mcp() {
    local store cfg before
    echo "== the Codex MCP table pointing into dist is removed =="
    new_sandbox codex
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$S/dotfiles" "$U_HOME/.codex"
    cat > "$S/dotfiles/codex.toml" <<TOML
model = "gpt-5"

[mcp_servers."activity-mesh"]
command = "node"
args = ["$store/dist/current/mcp/server.mjs"]

[mcp_servers."activity-mesh".env]
FOO = "bar"

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    chmod 640 "$S/dotfiles/codex.toml"
    ln -s "$S/dotfiles/codex.toml" "$U_HOME/.codex/config.toml"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    cfg="$S/dotfiles/codex.toml"
    [ -L "$U_HOME/.codex/config.toml" ] || fail "the config.toml symlink was replaced by a regular file"
    if grep -q 'activity-mesh' "$cfg"; then fail "the activity-mesh table or its sub-table survived: $(cat "$cfg")"; fi
    grep -qF 'model = "gpt-5"' "$cfg" && grep -qF '[mcp_servers.other]' "$cfg" && grep -qF 'command = "other-server"' "$cfg" \
        || fail "unrelated config was lost: $(cat "$cfg")"
    grep -qxF '# the other server' "$cfg" || fail "the comment that introduces the next table was removed with the block: $(cat "$cfg")"
    [ "$(mode_of "$cfg")" = "640" ] || fail "config.toml mode changed to $(mode_of "$cfg")"
    [ -n "$(find "$U_HOME/.codex" -name 'config.toml.bak-*')" ] || fail "no backup of config.toml"
    toml_ok "$cfg" || fail "config.toml is not valid TOML: $(cat "$cfg")"
    pass "the table and its sub-tables are removed from a symlinked config.toml; the rest stays"

    new_sandbox codex-repo
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.codex"
    cfg="$U_HOME/.codex/config.toml"
    printf '%s\n' '[mcp_servers.activity-mesh]' 'command = "node"' 'args = ["/repo/mcp/server.mjs"]' > "$cfg"
    before="$(sum_of "$cfg")"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "config.toml was rewritten although the table points at a repo checkout"
    pass "a table that points at a repo checkout is left alone"

    new_sandbox codex-order
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.codex"
    cfg="$U_HOME/.codex/config.toml"
    cat > "$cfg" <<TOML
model = "gpt-5"

[mcp_servers.activity-mesh.env]
FOO = "bar"

["mcp_servers"."activity-mesh"]
command = "node"
args = ["$store/dist/current/mcp/server.mjs"]

[[mcp_servers.activity-mesh.tools]]
name = "a"

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC"; }
    if grep -q 'mcp_servers.*activity-mesh' "$cfg"; then fail "a sub-table before the table, or an array-of-tables after it, survived: $(cat "$cfg")"; fi
    grep -qxF '# the other server' "$cfg" && grep -qxF '[mcp_servers.other]' "$cfg" && grep -qF 'model = "gpt-5"' "$cfg" || fail "unrelated config was lost: $(cat "$cfg")"
    toml_ok "$cfg" || fail "what is left of config.toml is not valid TOML: $(cat "$cfg")"
    if grep -q 'by hand' "$S/out.txt"; then fail "a clean strip reported leftovers: $(cat "$S/out.txt")"; fi
    pass "a sub-table before the table and an array-of-tables after it go with the table, and the rest still loads"
    if codex_usable; then
        codex_loads "$U_HOME" || fail "codex refuses to load what the uninstall left: $(cat "$cfg")"
        pass "the real codex loads what the uninstall left"
    else
        skip "codex is not usable here — its own loader was not consulted"
    fi
}

test_codex_inline_tables() {
    local store cfg before
    echo "== a registration the scanner cannot strip is reported =="
    new_sandbox inline
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.codex"
    cfg="$U_HOME/.codex/config.toml"

    cat > "$cfg" <<TOML
[mcp_servers]
activity-mesh = { command = "node", args = ["$store/dist/current/mcp/server.mjs"] }
TOML
    before="$(sum_of "$cfg")"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "an inline-table entry was edited"
    grep -q 'config.toml' "$S/out.txt" && grep -q 'by hand' "$S/out.txt" || fail "no warning about the inline-table entry: $(cat "$S/out.txt")"
    pass "an inline-table entry that points into dist is left in place with a warning"

    cat > "$cfg" <<TOML
mcp_servers = { activity-mesh = { command = "node", args = ["$store/dist/current/mcp/server.mjs"] } }
TOML
    uninstall_run "$S/out.txt" --
    grep -q 'by hand' "$S/out.txt" || fail "no warning about the top-level inline table: $(cat "$S/out.txt")"
    pass "so is a top-level inline table"

    cat > "$cfg" <<TOML
# args = ["$store/dist/current/mcp/server.mjs"]
[mcp_servers.other]
command = "other"
TOML
    before="$(sum_of "$cfg")"
    uninstall_run "$S/out.txt" --
    [ "$(sum_of "$cfg")" = "$before" ] || fail "a config that only mentions dist in a comment was edited"
    if grep -q 'by hand' "$S/out.txt"; then fail "a comment that mentions dist triggered a warning: $(cat "$S/out.txt")"; fi
    pass "a comment that mentions dist is neither edited nor reported"

    cat > "$cfg" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["$store/dist/current/mcp/server.mjs"]

[mcp_servers.helper]
command = "node"
args = ["$store/dist/1.0.0/mcp/helper.mjs"]
TOML
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    if grep -q '^\[mcp_servers\.activity-mesh\]' "$cfg"; then fail "the activity-mesh table survived: $(cat "$cfg")"; fi
    grep -qF '[mcp_servers.helper]' "$cfg" || fail "an unrelated server was removed: $(cat "$cfg")"
    grep -q 'by hand' "$S/out.txt" || fail "another server that points into dist was not reported after the strip: $(cat "$S/out.txt")"
    pass "after the strip, anything else in the file that still points into dist is reported"

    cat > "$cfg" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/repo/mcp/server.mjs"]

[mcp_servers.activity-mesh.env]
PATH = "$store/dist/bin"
TOML
    before="$(sum_of "$cfg")"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "a table that points at a repo checkout was edited because of its sub-table"
    grep -q 'by hand' "$S/out.txt" || fail "the sub-table that points into dist was not reported: $(cat "$S/out.txt")"
    pass "a sub-table that points into dist under a table that is not ours is reported, not edited"
}

test_hermes_warning() {
    local store cfg before
    echo "== a Hermes entry pointing into dist is reported, not edited =="
    new_sandbox hermes
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.hermes"
    cfg="$U_HOME/.hermes/config.yaml"
    printf 'mcp_servers:\n  activity-mesh:\n    command: node\n    args: ["%s/dist/current/mcp/server.mjs"]\n' "$store" > "$cfg"
    before="$(sum_of "$cfg")"
    uninstall_run "$S/out.txt" --
    [ "$RC" -eq 0 ] || fail "uninstall exited $RC"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "the Hermes config was edited"
    grep -q 'config.yaml' "$S/out.txt" && grep -q 'by hand' "$S/out.txt" || fail "no warning about the Hermes entry: $(cat "$S/out.txt")"
    pass "the Hermes entry is left in place with a warning"
}

test_registrations_dry_run() {
    local store before_s before_c before_t
    echo "== --dry-run leaves every registration alone =="
    if ! have jq; then skip "jq not found"; return 0; fi
    new_sandbox regdry
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.claude" "$U_HOME/.codex"
    cat > "$U_HOME/.claude/settings.json" <<JSON
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/session-start-digest.sh"}]}]}}
JSON
    cat > "$U_HOME/.claude.json" <<JSON
{"mcpServers": {"activity-mesh": {"command": "node", "args": ["$store/dist/current/mcp/server.mjs"]}}}
JSON
    printf '%s\n' '[mcp_servers.activity-mesh]' 'command = "node"' "args = [\"$store/dist/current/mcp/server.mjs\"]" > "$U_HOME/.codex/config.toml"
    before_s="$(sum_of "$U_HOME/.claude/settings.json")"
    before_c="$(sum_of "$U_HOME/.claude.json")"
    before_t="$(sum_of "$U_HOME/.codex/config.toml")"
    : > "$WORK/shim.log"
    uninstall_run "$S/out.txt" -- --dry-run
    [ "$RC" -eq 0 ] || fail "--dry-run exited $RC"
    [ "$(sum_of "$U_HOME/.claude/settings.json")" = "$before_s" ] || fail "--dry-run edited settings.json"
    [ "$(sum_of "$U_HOME/.claude.json")" = "$before_c" ] || fail "--dry-run edited ~/.claude.json"
    [ "$(sum_of "$U_HOME/.codex/config.toml")" = "$before_t" ] || fail "--dry-run edited config.toml"
    if grep -q 'mcp remove' "$WORK/shim.log"; then fail "--dry-run ran claude mcp remove"; fi
    [ -d "$store/dist" ] || fail "--dry-run removed dist"
    grep -q 'settings.json' "$S/out.txt" && grep -q 'config.toml' "$S/out.txt" && grep -q 'claude.json' "$S/out.txt" \
        || fail "--dry-run does not announce the registrations it would remove: $(cat "$S/out.txt")"
    pass "--dry-run announces the registrations and edits nothing"
}

test_without_jq() {
    local store before
    echo "== without jq the JSON registrations are reported, not touched =="
    make_nojq_path
    new_sandbox nojq
    store="$U_HOME/.local/share/activity-mesh"
    fake_store "$store" "$U_HOME/.local/state/activity-mesh"
    mkdir -p "$U_HOME/.claude"
    cat > "$U_HOME/.claude/settings.json" <<JSON
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$store/dist/current/hooks/session-start-digest.sh"}]}]}}
JSON
    before="$(sum_of "$U_HOME/.claude/settings.json")"
    NO_JQ=1
    uninstall_run "$S/out.txt" --
    NO_JQ=0
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall exited $RC without jq"; }
    [ "$(sum_of "$U_HOME/.claude/settings.json")" = "$before" ] || fail "settings.json was edited without jq"
    grep -q 'jq not found' "$S/out.txt" || fail "no warning about the missing jq: $(cat "$S/out.txt")"
    [ ! -e "$store/dist" ] || fail "dist was not removed"
    pass "a missing jq produces a warning and the rest of the uninstall still runs"
}

test_missing_helper() {
    local d
    echo "== uninstall.sh run without installers/lib refuses before touching anything =="
    new_sandbox nolib
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    d="$S/copy/installers"
    mkdir -p "$d"
    cp "$REPO_ROOT/installers/uninstall.sh" "$d/uninstall.sh"
    set +e
    env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" bash "$d/uninstall.sh" --purge > "$S/out.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -ne 0 ] && grep -q 'cfgedit.sh' "$S/out.txt" || fail "uninstall.sh did not refuse without its helper (rc=$RC): $(cat "$S/out.txt")"
    [ -d "$U_HOME/.local/share/activity-mesh/dist" ] && [ -e "$U_PREFIX/activity-log" ] || fail "something was removed before the refusal"
    pass "uninstall.sh names the missing helper and changes nothing"
}

test_symlinked_script() {
    local tree bin
    echo "== uninstall.sh started through a symlink finds its helper =="
    new_sandbox symlink
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    tree="$S/tree/installers"
    bin="$S/bin"
    mkdir -p "$tree/lib" "$bin"
    cp "$REPO_ROOT/installers/uninstall.sh" "$tree/uninstall.sh"
    cp "$REPO_ROOT/installers/lib/cfgedit.sh" "$tree/lib/cfgedit.sh"
    ln -s "$tree/uninstall.sh" "$bin/uninstall-link"
    ln -s uninstall-link "$bin/uninstall-chain"
    set +e
    env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" bash "$bin/uninstall-chain" > "$S/out.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall.sh exited $RC through a chain of symlinks"; }
    [ ! -e "$U_HOME/.local/share/activity-mesh/dist" ] || fail "the run through a symlink did not remove dist"
    pass "uninstall.sh finds its helper through a chain of symlinks"
}

ident_sandbox() {
    new_sandbox "$1"
    printf 'keep\n' > "$U_HOME/sentinel.txt"
    mkdir -p "$U_HOME/dist"
}

expect_refused_with() {
    local fragment="$1"
    shift
    expect_refused "$@"
    grep -qF -- "$fragment" "$S/out-refused.txt" || fail "the refusal of $1=$2 does not say [$fragment]: $(cat "$S/out-refused.txt")"
}

expect_accepted() {
    local name="$1" dir="$2" canon
    canon="$(cd -P "$dir" && /bin/pwd -P)"
    uninstall_run "$S/out-ok.txt" "$name=$dir" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-ok.txt" >&2; fail "$name=$dir was refused although it has the shape of activity-mesh's own dir"; }
    grep -qxF "DRY rm -rf $canon" "$S/out-ok.txt" || fail "$name=$dir is not planned for removal: $(cat "$S/out-ok.txt")"
}

test_volume_roots() {
    local v ids dev ino
    echo "== a volume root, in every spelling, is refused (dry-run) =="
    ident_sandbox volroot
    if [ -d /System/Volumes/Data ]; then
        ids="$(fs_id /System/Volumes/Data)"
        dev="${ids%%:*}"
        ino="${ids#*:}"
        for v in /System/Volumes/Data /System/Volumes/Data/ /System/Volumes/Data/. /System/Volumes /System "/.vol/$dev/$ino"; do
            expect_refused ACTIVITY_MESH_HOME "$v"
            expect_refused ACTIVITY_MESH_STATE "$v"
        done
        SKIPPED_SPELLINGS=0
        for v in /SYSTEM/VOLUMES/DATA /system/volumes/data; do
            expect_refused_alias ACTIVITY_MESH_HOME "$v" /System/Volumes/Data
            expect_refused_alias ACTIVITY_MESH_STATE "$v" /System/Volumes/Data
        done
        pass "the data volume root, its parents, its case spellings and its /.vol spelling are refused"
    else
        skip "no /System/Volumes/Data on this system"
    fi
    if [ -d /dev/shm ] && [ "$(fs_id /dev/shm | cut -d: -f1)" != "$(fs_id /dev | cut -d: -f1)" ]; then
        expect_refused ACTIVITY_MESH_STATE /dev/shm
        pass "a mount point is refused (/dev/shm)"
    fi
}

test_foreign_dirs() {
    echo "== a directory that is not activity-mesh's own is refused, whatever it is called (dry-run) =="
    ident_sandbox foreign
    mkdir -p "$S/decoy/bin" "$S/decoy/lib" "$S/decoy/share"
    : > "$S/decoy/readme.txt"
    mkdir -p "$S/half/Documents"
    : > "$S/half/index.db"
    mkdir -p "$S/hidden/.git"
    : > "$S/hidden/index.db"
    mkdir -p "$S/emptydir" "$S/logs/archive" "$S/many/a" "$S/many/b" "$S/many/c" "$S/many/d" "$S/many/e" "$S/many/f" "$S/many/g"
    : > "$S/logs/a.log"
    : > "$S/many/index.db"
    expect_refused_with "bin/, lib/, share/" ACTIVITY_MESH_HOME "$S/decoy"
    expect_refused_with "bin/, lib/, share/" ACTIVITY_MESH_STATE "$S/decoy"
    expect_refused_with "Documents/" ACTIVITY_MESH_HOME "$S/half"
    expect_refused_with ".git/" ACTIVITY_MESH_HOME "$S/hidden"
    expect_refused_with "empty dir" ACTIVITY_MESH_HOME "$S/emptydir"
    expect_refused_with "empty dir" ACTIVITY_MESH_STATE "$S/emptydir"
    expect_refused_with "archive/" ACTIVITY_MESH_STATE "$S/logs"
    pass "foreign subdirectories, a foreign hidden directory, a dir with markers and a foreign subdir, and an empty dir are all refused, naming what is in the way"

    expect_refused_with "(and 2 more)" ACTIVITY_MESH_HOME "$S/many"
    grep -qF "a/, b/, c/, d/, e/ (and 2 more)" "$S/out-refused.txt" || fail "the first five unexpected entries are not listed: $(cat "$S/out-refused.txt")"
    if grep -qF "f/" "$S/out-refused.txt"; then fail "more than five unexpected entries are listed: $(cat "$S/out-refused.txt")"; fi
    pass "at most five unexpected entries are listed, with a count of the rest"

    mkdir -p "$S/flat"
    : > "$S/flat/readme.txt"
    : > "$S/flat/notes.md"
    expect_refused_with "it holds only: notes.md, readme.txt" ACTIVITY_MESH_HOME "$S/flat"
    pass "a directory with files but none of activity-mesh's is refused, naming what it does hold"

    mkdir -p "$U_HOME/.config/activity-mesh/notes"
    : > "$U_HOME/.config/activity-mesh/watcher.yaml"
    uninstall_run "$S/out-cfg.txt" -- --purge --dry-run
    [ "$RC" -ne 0 ] || fail "a config dir with a foreign subdirectory must be refused"
    grep -q 'CONFIG_DIR' "$S/out-cfg.txt" && grep -qF 'notes/' "$S/out-cfg.txt" || fail "the refusal does not name the config dir and what is in it: $(cat "$S/out-cfg.txt")"
    if grep -q 'DRY' "$S/out-cfg.txt"; then fail "the plan started although the config dir has a foreign subdirectory"; fi
    rm -rf "$U_HOME/.config/activity-mesh"
    pass "the config dir is held to the same rule"

    mkdir -p "$S/dist-store/dist/Documents" "$S/dist-store/dist/1.0.0"
    ln -s 1.0.0 "$S/dist-store/dist/current"
    : > "$S/dist-store/index.db"
    uninstall_run "$S/out-dist.txt" ACTIVITY_MESH_HOME="$S/dist-store" -- --dry-run
    [ "$RC" -ne 0 ] && grep -qF 'Documents/' "$S/out-dist.txt" || fail "a dist dir with a foreign subdirectory must be refused even without --purge: $(cat "$S/out-dist.txt")"
    if grep -q 'DRY' "$S/out-dist.txt"; then fail "the plan started although dist holds a foreign subdirectory"; fi
    rm -rf "$S/dist-store/dist/Documents"
    : > "$S/dist-store/dist/bundle.js"
    uninstall_run "$S/out-dist.txt" ACTIVITY_MESH_HOME="$S/dist-store" -- --dry-run
    [ "$RC" -ne 0 ] && grep -qF 'bundle.js' "$S/out-dist.txt" || fail "a dist dir with a foreign file must be refused: $(cat "$S/out-dist.txt")"
    rm -f "$S/dist-store/dist/bundle.js"
    mkdir -p "$S/dist-store/dist/current-copy"
    uninstall_run "$S/out-dist.txt" ACTIVITY_MESH_HOME="$S/dist-store" -- --dry-run
    [ "$RC" -ne 0 ] && grep -qF 'current-copy/' "$S/out-dist.txt" || fail "a dist dir with a directory that is no version must be refused: $(cat "$S/out-dist.txt")"
    pass "without --purge the dist dir must hold only version dirs and current"

    mkdir -p "$S/lone/bin" "$S/lone/lib"
    uninstall_run "$S/out-lone.txt" ACTIVITY_MESH_HOME="$S/lone" -- --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-lone.txt" >&2; fail "a store with foreign subdirectories but no dist was refused although nothing in it is removed"; }
    pass "without --purge nothing outside dist is removed, so nothing outside dist is examined"
}

test_real_shapes() {
    local st
    echo "== the directories activity-mesh makes are accepted, in every shape they come in (dry-run) =="
    ident_sandbox shapes
    mkdir -p "$S/st1/audit" "$S/st1/dist/0.4.0-rc.7" "$S/st1/dist/v0.4.0" "$S/st1/dist/dev-local" "$S/st1/dist/1.0.0-local"
    ln -s 0.4.0-rc.7 "$S/st1/dist/current"
    : > "$S/st1/config.json"
    : > "$S/st1/seq-macbook"
    : > "$S/st1/.DS_Store"
    : > "$S/st1/dist/.DS_Store"
    mkdir -p "$S/st2" "$S/st3/dist/1.0.0" "$S/st4" "$S/st5" "$S/st6/dist"
    : > "$S/st2/seq-host"
    ln -s 1.0.0 "$S/st3/dist/current"
    : > "$S/st4/cursors.json"
    : > "$S/st5/index.db"
    : > "$S/st6/index.db"
    for st in st1 st2 st3 st4 st5 st6; do
        expect_accepted ACTIVITY_MESH_HOME "$S/$st"
    done
    pass "a store is accepted with audit and dist, or with just one of config.json, cursors.json, index.db, seq-*, dist/current; versions are numbers, v-numbers or dev-local"

    st="/System/Volumes/Data$(cd -P "$S/st1" && /bin/pwd -P)"
    if [ -d /System/Volumes/Data ] && [ "$(fs_id "$st" 2>/dev/null)" = "$(fs_id "$S/st1")" ]; then
        expect_accepted ACTIVITY_MESH_HOME "$st"
        pass "a store spelled through /System/Volumes/Data is accepted: that protection is for HOME, the sync dir and their parents"
    fi

    mkdir -p "$S/sa" "$S/sb" "$S/sc" "$S/sd" "$S/se"
    : > "$S/sa/tokens-abc"
    : > "$S/sb/last-health.json"
    : > "$S/sc/daemon.err"
    : > "$S/sd/heartbeat-misses"
    : > "$S/se/clock-offset-ms"
    for st in sa sb sc sd se; do
        expect_accepted ACTIVITY_MESH_STATE "$S/$st"
    done
    pass "a state dir is accepted with any one of its files"

    mkdir -p "$U_HOME/.config/activity-mesh"
    : > "$U_HOME/.config/activity-mesh/agents-cache"
    uninstall_run "$S/out-cfg.txt" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-cfg.txt" >&2; fail "a config dir that holds only agents-cache was refused"; }
    grep -qxF "DRY rm -rf $(cd -P "$U_HOME/.config/activity-mesh" && /bin/pwd -P)" "$S/out-cfg.txt" || fail "the config dir is not planned for removal"
    pass "a config dir is accepted with any one of its files"
}

test_link_chains() {
    local link
    echo "== --purge through a chain of links removes every link that pointed into the purged dir =="
    new_sandbox chains
    mkdir -p "$S/real-store/dist/0.1" "$S/real-state" "$S/linkdir-target/inner-store" "$S/cfg-real"
    : > "$S/real-store/index.db"
    : > "$S/real-state/health.log"
    : > "$S/linkdir-target/inner-store/index.db"
    : > "$S/cfg-real/watcher.yaml"
    ln -s real-store "$S/chain2"
    ln -s chain2 "$S/chain1"
    ln -s "$S/real-state" "$S/schain2"
    ln -s schain2 "$S/schain1"
    ln -s linkdir-target "$S/linkdir"
    mkdir -p "$U_HOME/.config"
    ln -s "$S/cfg-real" "$U_HOME/.config/activity-mesh"
    uninstall_run "$S/out-dry.txt" ACTIVITY_MESH_HOME="$S/chain1" ACTIVITY_MESH_STATE="$S/schain1" -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-dry.txt" >&2; fail "the dry run exited $RC"; }
    for link in '/chain1' '/chain2' '/schain1' '/schain2' '/.config/activity-mesh'; do
        grep -q "^DRY rm -f .*$link\$" "$S/out-dry.txt" || fail "the dry run does not plan to remove the link ...$link: $(grep 'DRY rm -f' "$S/out-dry.txt")"
    done
    [ -e "$S/real-store" ] && [ -L "$S/chain1" ] && [ -L "$S/chain2" ] || fail "the dry run changed something"

    uninstall_run "$S/out.txt" ACTIVITY_MESH_HOME="$S/chain1" ACTIVITY_MESH_STATE="$S/schain1" -- --purge
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "--purge exited $RC"; }
    [ ! -e "$S/real-store" ] && [ ! -e "$S/real-state" ] && [ ! -e "$S/cfg-real" ] || fail "--purge left a directory behind"
    [ ! -L "$S/chain1" ] && [ ! -L "$S/chain2" ] || fail "a link of the store chain was left dangling"
    [ ! -L "$S/schain1" ] && [ ! -L "$S/schain2" ] || fail "a link of the state chain was left dangling"
    [ ! -L "$U_HOME/.config/activity-mesh" ] || fail "the link to the config dir was left dangling"
    [ -d "$U_HOME" ] || fail "HOME disappeared"
    pass "a chain of two links (relative, absolute) to the store and to the state dir, and a link to the config dir, are removed with what they pointed to"

    uninstall_run "$S/out-mid.txt" ACTIVITY_MESH_HOME="$S/linkdir/inner-store" -- --purge
    [ "$RC" -eq 0 ] || { cat "$S/out-mid.txt" >&2; fail "--purge through a linked parent exited $RC"; }
    [ ! -e "$S/linkdir-target/inner-store" ] || fail "--purge left the store behind"
    [ -L "$S/linkdir" ] && [ -d "$S/linkdir-target" ] || fail "a link that only led to the store's parent was removed"
    pass "a link that points at the parent of the purged dir, not at the dir, stays"
}

test_residuals() {
    local box
    echo "== names that resolve to something else, and padded sync dirs =="
    ident_sandbox residual
    mkdir -p "$U_HOME/Documents" "$U_HOME/Documents"$'\n'
    printf 'precious\n' > "$U_HOME/Documents/thesis.txt"
    ln -s "$U_HOME/Documents"$'\n' "$S/store-link"
    uninstall_run "$S/out-nl.txt" ACTIVITY_MESH_HOME="$S/store-link" -- --purge --dry-run
    [ "$RC" -ne 0 ] || fail "a link to a directory whose name ends in a newline must be refused"
    grep -qF 'does not resolve to the directory it names' "$S/out-nl.txt" || fail "the refusal does not say why: $(cat "$S/out-nl.txt")"
    if grep -q 'DRY' "$S/out-nl.txt"; then fail "the plan started: $(cat "$S/out-nl.txt")"; fi
    [ -f "$U_HOME/Documents/thesis.txt" ] || fail "the other Documents directory was touched"
    pass "a path whose resolved name is a different directory (a trailing newline lost to command substitution) is refused"

    box="$U_HOME/Box/sync"
    mkdir -p "$box"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Box" "ACTIVITY_MESH_SYNC= $box "
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Box" "ACTIVITY_MESH_SYNC=$(printf '\t')$box$(printf '\t')"
    mkdir -p "$U_HOME/.local/share/activity-mesh"
    printf '{"sync_dir": "  %s  "}\n' "$box" > "$U_HOME/.local/share/activity-mesh/config.json"
    expect_refused ACTIVITY_MESH_STATE "$U_HOME/Box"
    uninstall_run "$S/out-pad.txt" -- --purge --dry-run
    grep -qF "$box alone" "$S/out-pad.txt" || fail "the padded sync_dir is not named without its padding: $(grep -i alone "$S/out-pad.txt")"
    uninstall_run "$S/out-blank.txt" "ACTIVITY_MESH_SYNC=   " -- --purge --dry-run
    [ "$RC" -eq 0 ] || { cat "$S/out-blank.txt" >&2; fail "a blank ACTIVITY_MESH_SYNC stopped the uninstall"; }
    pass "blanks around ACTIVITY_MESH_SYNC or sync_dir are trimmed, the way the CLI trims them; a blank value is ignored"
}

make_nostat_path() {
    local c p
    mkdir -p "$WORK/nostat"
    for c in bash uname id dirname rm mktemp cp cmp date grep readlink mv chmod cat sed tr wc head ls; do
        p="$(command -v "$c" 2>/dev/null || true)"
        if [ -n "$p" ] && [ ! -e "$WORK/nostat/$c" ]; then ln -s "$p" "$WORK/nostat/$c"; fi
    done
}

test_fail_closed() {
    local mut
    echo "== when identities cannot be read, nothing is removed =="
    ident_sandbox closed
    mkdir -p "$S/dedicated"
    : > "$S/dedicated/index.db"
    set +e
    env -i HOME="$S/no-such-home" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" ACTIVITY_MESH_HOME="$S/dedicated" \
        bash "$REPO_ROOT/installers/uninstall.sh" --purge --dry-run > "$S/out-nohome.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -ne 0 ] && grep -qF 'cannot read the identity of HOME' "$S/out-nohome.txt" || fail "a HOME that does not exist must stop the uninstall (rc=$RC): $(cat "$S/out-nohome.txt")"
    if grep -q 'DRY' "$S/out-nohome.txt"; then fail "the plan started without a HOME: $(cat "$S/out-nohome.txt")"; fi
    pass "a HOME whose identity cannot be read stops the uninstall before anything is planned"

    make_nostat_path
    set +e
    env -i HOME="$U_HOME" PATH="$SHIM:$WORK/nostat" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" ACTIVITY_MESH_HOME="$S/dedicated" \
        bash "$REPO_ROOT/installers/uninstall.sh" --purge --dry-run > "$S/out-nostat.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -ne 0 ] && grep -qF 'identity' "$S/out-nostat.txt" || fail "without stat the uninstall must stop (rc=$RC): $(cat "$S/out-nostat.txt")"
    if grep -q 'DRY' "$S/out-nostat.txt"; then fail "the plan started without stat: $(cat "$S/out-nostat.txt")"; fi
    [ -f "$S/dedicated/index.db" ] || fail "the store was touched"
    pass "without stat even a dedicated directory is not purged"

    if [ "$(uname -s)" = Darwin ]; then
        mut="$S/mut/installers"
        mkdir -p "$mut/lib"
        sed 's|/usr/bin/pwd|/nonexistent/pwd2|g; s|/bin/pwd|/nonexistent/pwd1|g' "$REPO_ROOT/installers/uninstall.sh" > "$mut/uninstall.sh"
        sed 's|/usr/bin/pwd|/nonexistent/pwd2|g; s|/bin/pwd|/nonexistent/pwd1|g' "$REPO_ROOT/installers/lib/cfgedit.sh" > "$mut/lib/cfgedit.sh"
        set +e
        env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" ACTIVITY_MESH_HOME="$S/dedicated" \
            bash "$mut/uninstall.sh" --purge --dry-run > "$S/out-nopwd.txt" 2>&1
        RC=$?
        set -e
        [ "$RC" -ne 0 ] && grep -qF 'cannot be resolved to the name the filesystem stores' "$S/out-nopwd.txt" || fail "on darwin without a pwd binary the uninstall must stop (rc=$RC): $(cat "$S/out-nopwd.txt")"
        pass "on darwin, without /bin/pwd and /usr/bin/pwd, the builtin is not trusted and the uninstall stops"
    else
        skip "not darwin: the builtin pwd is trusted on a case-sensitive filesystem"
    fi
}

test_decoy_layout() {
    local real decoy
    echo "== uninstall.sh reached through a symlinked directory sources the helper next to the real script =="
    new_sandbox decoylayout
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    real="$S/dotfiles/tree/installers"
    decoy="$S/tree/installers"
    mkdir -p "$real/lib" "$decoy/lib" "$S/dotfiles/bin"
    cp "$REPO_ROOT/installers/uninstall.sh" "$real/uninstall.sh"
    cp "$REPO_ROOT/installers/lib/cfgedit.sh" "$real/lib/cfgedit.sh"
    printf '%s\n' 'echo DECOY-HELPER-SOURCED >&2' 'exit 97' > "$decoy/lib/cfgedit.sh"
    ln -s ../tree/installers/uninstall.sh "$S/dotfiles/bin/uninstall-link"
    ln -s dotfiles/bin "$S/bin"
    set +e
    env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" bash "$S/bin/uninstall-link" > "$S/out.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -eq 0 ] || { cat "$S/out.txt" >&2; fail "uninstall.sh exited $RC through a symlinked directory with a decoy at the path's own location"; }
    [ ! -e "$U_HOME/.local/share/activity-mesh/dist" ] || fail "the run did not remove dist"
    fake_store "$U_HOME/.local/share/activity-mesh" "$U_HOME/.local/state/activity-mesh"
    set +e
    env -i HOME="$U_HOME" PATH="$(run_path)" PREFIX="$U_PREFIX" TMPDIR="$WORK/tmp" bash "$S/bin/../tree/installers/uninstall.sh" > "$S/out-dotdot.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -eq 0 ] || { cat "$S/out-dotdot.txt" >&2; fail "uninstall.sh exited $RC when started by a path that goes through a symlinked directory and .."; }
    pass "the helper next to the real script is the one that is sourced"
}

test_default_dirs
test_env_dirs
test_unsafe_dirs
test_sync_protection
test_store_spellings
test_odd_paths
test_dry_run
test_alternate_prefix
test_claude_hooks
test_claude_mcp
test_codex_mcp
test_codex_inline_tables
test_hermes_warning
test_registrations_dry_run
test_without_jq
test_missing_helper
test_symlinked_script
test_decoy_layout
test_volume_roots
test_foreign_dirs
test_real_shapes
test_link_chains
test_residuals
test_fail_closed

echo
echo "ALL UNINSTALL TESTS PASSED"
