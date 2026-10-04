#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/amesh-uninstall-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
sum_of() { cksum < "$1"; }

mkdir -p "$WORK/tmp" "$WORK/shim"
SHIM="$WORK/shim"
for c in launchctl systemctl loginctl sudo claude; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/shim.log"\nexit 0\n' "$c" "$WORK" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
BASE_PATH="/usr/bin:/bin"
RC=0
S=""
U_HOME=""
U_PREFIX=""

new_sandbox() {
    local b
    S="$WORK/$1"
    U_HOME="$S/home"
    U_PREFIX="$S/prefix"
    mkdir -p "$U_HOME" "$U_PREFIX"
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
    env -i HOME="$U_HOME" PATH="$SHIM:$BASE_PATH" PREFIX="$U_PREFIX" ${envs[@]+"${envs[@]}"} \
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

test_unsafe_dirs() {
    local before
    echo "== a store or state dir that is / or HOME is refused =="
    new_sandbox unsafe
    printf 'keep\n' > "$U_HOME/sentinel.txt"
    mkdir -p "$U_HOME/dist"
    before="$(sum_of "$U_HOME/sentinel.txt")"
    uninstall_run "$S/out-home.txt" ACTIVITY_MESH_HOME="$U_HOME" -- --purge
    [ "$RC" -ne 0 ] || fail "ACTIVITY_MESH_HOME=\$HOME must be refused"
    grep -q 'ACTIVITY_MESH_HOME' "$S/out-home.txt" || fail "the refusal does not name ACTIVITY_MESH_HOME: $(cat "$S/out-home.txt")"
    [ -d "$U_HOME/dist" ] && [ "$(sum_of "$U_HOME/sentinel.txt")" = "$before" ] || fail "HOME was modified"
    [ -e "$U_PREFIX/activity-log" ] || fail "binaries were removed before the refusal"
    uninstall_run "$S/out-root.txt" ACTIVITY_MESH_STATE=/ -- --purge
    [ "$RC" -ne 0 ] || fail "ACTIVITY_MESH_STATE=/ must be refused"
    grep -q 'ACTIVITY_MESH_STATE' "$S/out-root.txt" || fail "the refusal does not name ACTIVITY_MESH_STATE: $(cat "$S/out-root.txt")"
    uninstall_run "$S/out-dot.txt" ACTIVITY_MESH_HOME=. -- --purge --dry-run
    [ "$RC" -ne 0 ] || fail "ACTIVITY_MESH_HOME=. must be refused"
    pass "directories that would take HOME or / with them are refused before anything changes"
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

test_default_dirs
test_env_dirs
test_unsafe_dirs
test_odd_paths
test_dry_run

echo
echo "ALL UNINSTALL TESTS PASSED"
