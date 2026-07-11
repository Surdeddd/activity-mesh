#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v goreleaser >/dev/null 2>&1 || { echo "SKIP: goreleaser not installed"; exit 0; }

rm -rf dist
goreleaser release --snapshot --clean --skip=sign,sbom,publish,announce >/dev/null 2>&1 \
    || fail "goreleaser snapshot build failed"

shopt -s nullglob
TARBALLS=(dist/activity-mesh_*_{linux,darwin}_*.tar.gz)
ZIPS=(dist/activity-mesh_*_windows_*.zip)
shopt -u nullglob

[ "${#TARBALLS[@]}" -ge 4 ] || fail "expected >=4 unix tarballs, got ${#TARBALLS[@]}"
[ "${#ZIPS[@]}" -ge 1 ] || fail "expected a windows zip"
pass "archives produced: ${#TARBALLS[@]} unix + ${#ZIPS[@]} windows"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for t in "${TARBALLS[@]}"; do
    listing="$(tar -tzf "$t")"
    for b in activity-log activity-watcher activity-mesh-daemon; do
        echo "$listing" | grep -qx "$b" || fail "$(basename "$t"): missing binary $b"
    done
    for asset in VERSION health/master.sh configs/watcher.yaml registries/kinds.yaml hooks/user-prompt-router.sh mcp/server.mjs installers/bootstrap.sh installers/templates/launchd-daemon.plist.tmpl; do
        echo "$listing" | grep -qx "$asset" || fail "$(basename "$t"): missing asset $asset"
    done
done
pass "unix tarballs contain 3 binaries + runtime assets"

for z in "${ZIPS[@]}"; do
    rm -rf "$WORK/z" && mkdir -p "$WORK/z"
    (cd "$WORK/z" && unzip -qq "$REPO_ROOT/$z")
    [ -f "$WORK/z/activity-log.exe" ] || fail "$(basename "$z"): missing activity-log.exe"
    [ ! -f "$WORK/z/activity-watcher.exe" ] || fail "$(basename "$z"): watcher must NOT ship on windows (CLI-only)"
    [ ! -f "$WORK/z/activity-mesh-daemon.exe" ] || fail "$(basename "$z"): daemon must NOT ship on windows (CLI-only)"
    [ -f "$WORK/z/registries/kinds.yaml" ] || fail "$(basename "$z"): missing registries"
done
pass "windows zip is CLI-only (activity-log.exe + assets)"

[ -f dist/checksums.txt ] || fail "checksums.txt missing"
for a in "${TARBALLS[@]}" "${ZIPS[@]}"; do
    grep -q " $(basename "$a")\$" dist/checksums.txt || fail "checksums.txt lacks $(basename "$a")"
done
pass "checksums.txt covers every archive"

rm -rf dist
echo
echo "ALL ARCHIVE TESTS PASSED"
