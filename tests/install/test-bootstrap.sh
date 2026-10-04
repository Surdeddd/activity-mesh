#!/usr/bin/env bash
set -euo pipefail
unset ACTIVITY_MESH_SYNC ACTIVITY_MESH_HOME ACTIVITY_MESH_STATE ACTIVITY_MESH_CONFIG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/amesh-install-test.XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }
nosvc_units() {
    if [ "$OS" = "darwin" ]; then echo "$1/.local/share/activity-mesh/dist/$VER/units"; else echo "$1/.config/systemd/user"; fi
}
BOOTSTRAP="$REPO_ROOT/installers/bootstrap.sh"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
esac
VER="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
ARCHIVE="activity-mesh_${VER}_${OS}_${ARCH}.tar.gz"

echo "== building binaries =="
STAGE="$WORK/stage"
mkdir -p "$STAGE"
(cd "$REPO_ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$VER" -o "$STAGE/activity-log" ./cmd/activity-log)
(cd "$REPO_ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$VER" -o "$STAGE/activity-watcher" ./cmd/activity-watcher)
(cd "$REPO_ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$VER" -o "$STAGE/activity-mesh-daemon" ./server)

echo "== assembling fake release =="
for d in installers health registries configs hooks mcp; do
    cp -R "$REPO_ROOT/$d" "$STAGE/$d"
done
for f in VERSION README.md CHANGELOG.md LICENSE; do
    cp "$REPO_ROOT/$f" "$STAGE/$f"
done
RELEASE="$WORK/release"
mkdir -p "$RELEASE"
(cd "$STAGE" && tar -czf "$RELEASE/$ARCHIVE" .)
(cd "$RELEASE" && sum256 "$ARCHIVE" > checksums.txt)

echo "== serving fake release on localhost =="
PORT=$(( (RANDOM % 20000) + 20000 ))
(cd "$RELEASE" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -fso /dev/null "http://127.0.0.1:$PORT/checksums.txt" && break
    sleep 0.1
done

echo "== running bootstrap in hermetic HOME =="
FAKE_HOME="$WORK/home"
PREFIX_DIR="$WORK/bin"
mkdir -p "$FAKE_HOME"
set +e
HOME="$FAKE_HOME" PREFIX="$PREFIX_DIR" \
    ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services \
    > "$WORK/bootstrap.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    cat "$WORK/bootstrap.out" >&2
    fail "bootstrap exited $RC"
fi
grep -q "bootstrap complete" "$WORK/bootstrap.out" || fail "no 'bootstrap complete' line"
pass "bootstrap completed via curl-pipe-equivalent flow"

for b in activity-log activity-watcher activity-mesh-daemon; do
    [ -x "$PREFIX_DIR/$b" ] || fail "$b not installed to PREFIX"
done
[ -z "$(find "$PREFIX_DIR" -name '.*.new' 2>/dev/null)" ] || fail "staged binaries left in PREFIX after a successful install"
pass "3 binaries installed"

ASSETS="$FAKE_HOME/.local/share/activity-mesh/dist/$VER"
for req in health/master.sh health/lib.sh configs/watcher.yaml registries/kinds.yaml hooks/user-prompt-router.sh mcp/server.mjs installers/templates/launchd-daemon.plist.tmpl; do
    [ -f "$ASSETS/$req" ] || fail "asset missing: $ASSETS/$req"
done
[ -L "$FAKE_HOME/.local/share/activity-mesh/dist/current" ] || fail "current symlink missing"
pass "versioned runtime assets installed"

UNITS_DIR="$(nosvc_units "$FAKE_HOME")"
if [ "$OS" = "darwin" ]; then
    N_UNITS=6
    if [ -n "$(find "$FAKE_HOME/Library/LaunchAgents" -name "*activity-mesh*" 2>/dev/null || true)" ]; then
        fail "--no-services wrote plists into ~/Library/LaunchAgents (launchd loads them at login)"
    fi
else
    N_UNITS=2
fi
COUNT=$(find "$UNITS_DIR" -name "*activity-mesh*" 2>/dev/null | wc -l | tr -d " " || true)
[ "$COUNT" -eq "$N_UNITS" ] || fail "expected $N_UNITS rendered units in $UNITS_DIR, got $COUNT"
if grep -rq "{{[A-Z_]*}}" "$UNITS_DIR"; then
    fail "unresolved placeholder in rendered units"
fi
if grep -rq "$REPO_ROOT" "$UNITS_DIR"; then
    fail "rendered units reference the repo checkout"
fi
if [ "$OS" = "darwin" ]; then
    grep -rq "dist/current" "$UNITS_DIR" || fail "health/heartbeat/digest units must reference the versioned assets dir"
fi
grep -rq "$PREFIX_DIR" "$UNITS_DIR" || fail "units do not reference the installed binaries"
pass "units rendered from versioned assets/prefix, no checkout references"

if [ "$OS" = "darwin" ]; then
    grep -A1 '<key>ACTIVITY_MESH_BIN</key>' "$UNITS_DIR/com.activity-mesh.watcher.plist" \
        | grep -qF "<string>$PREFIX_DIR/activity-log</string>" \
        || fail "watcher unit must point ACTIVITY_MESH_BIN at the installed CLI"
else
    grep -qxF "Environment=ACTIVITY_MESH_BIN=$PREFIX_DIR/activity-log" "$UNITS_DIR/activity-mesh-watcher.service" \
        || fail "watcher unit must point ACTIVITY_MESH_BIN at the installed CLI"
fi
if grep -q "shadows" "$WORK/bootstrap.out"; then
    fail "shadow warning without a ~/.local/bin/activity-log"
fi
pass "watcher unit points ACTIVITY_MESH_BIN at the installed CLI"

if [ "$OS" = "darwin" ]; then
    for unit in health heartbeat; do
        plist="$UNITS_DIR/com.activity-mesh.$unit.plist"
        [ -f "$plist" ] || fail "rendered $unit unit missing: $plist"
        grep -A1 '<key>RunAtLoad</key>' "$plist" | grep '<false/>' >/dev/null \
            || fail "$unit unit must wait for its calendar slot (RunAtLoad must be false)"
    done
    pass "health and heartbeat units wait for their calendar slot"
fi

for reg in kinds scopes agents redaction; do
    [ -f "$FAKE_HOME/Sync/activity/$reg.yaml" ] || fail "registry not seeded: $reg.yaml"
done
[ -f "$FAKE_HOME/.config/activity-mesh/watcher.yaml" ] || fail "watcher.yaml not installed"
pass "registries + watcher.yaml seeded"

HOME="$FAKE_HOME" "$PREFIX_DIR/activity-log" query --since 24h --format text | grep -q "installed on" \
    || fail "smoke event not queryable"
pass "smoke emit is queryable"

echo "== an archive without the runtime layout must not touch the install =="
OLD_STAGE="$WORK/stage-old"
mkdir -p "$OLD_STAGE"
for b in activity-log activity-watcher activity-mesh-daemon; do
    printf '#!/bin/sh\necho "%s 0.3.2"\n' "$b" > "$OLD_STAGE/$b"
    chmod +x "$OLD_STAGE/$b"
done
cp -R "$REPO_ROOT/installers" "$REPO_ROOT/registries" "$REPO_ROOT/configs" "$OLD_STAGE/"
echo "0.3.2" > "$OLD_STAGE/VERSION"
OLD_ARCHIVE="activity-mesh_0.3.2_${OS}_${ARCH}.tar.gz"
(cd "$OLD_STAGE" && tar -czf "$RELEASE/$OLD_ARCHIVE" .)
(cd "$RELEASE" && sum256 "$OLD_ARCHIVE" >> checksums.txt)
BIN_BEFORE="$(cksum < "$PREFIX_DIR/activity-log")"
CURRENT_BEFORE="$(readlink "$FAKE_HOME/.local/share/activity-mesh/dist/current")"
HOME="$FAKE_HOME" PREFIX="$PREFIX_DIR" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version v0.3.2 --no-services > "$WORK/bootstrap-old.out" 2>&1 && RC_OLD=0 || RC_OLD=$?
[ "$RC_OLD" -ne 0 ] || fail "bootstrap must refuse an archive without health/"
[ "$(cksum < "$PREFIX_DIR/activity-log")" = "$BIN_BEFORE" ] || fail "binaries were replaced before the archive layout was validated"
[ "$(readlink "$FAKE_HOME/.local/share/activity-mesh/dist/current")" = "$CURRENT_BEFORE" ] || fail "dist/current re-pointed by a refused archive"
grep -q "refusing to install" "$WORK/bootstrap-old.out" || fail "no layout diagnostics: $(tail -2 "$WORK/bootstrap-old.out")"
pass "an archive without health/ is refused before anything is installed"

echo "== a refused sudo for a read-only prefix changes nothing =="
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: root ignores directory permissions"
else
    RO_HOME="$WORK/home-ro"
    RO_BIN="$WORK/bin-ro"
    RO_STORE="$RO_HOME/.local/share/activity-mesh"
    mkdir -p "$RO_HOME"
    HOME="$RO_HOME" PREFIX="$RO_BIN" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
        bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-ro1.out" 2>&1 && RC_RO1=0 || RC_RO1=$?
    [ "$RC_RO1" -eq 0 ] || { cat "$WORK/bootstrap-ro1.out" >&2; fail "read-only prefix: first install exited $RC_RO1"; }
    NEXT_ARCHIVE="activity-mesh_9.9.9_${OS}_${ARCH}.tar.gz"
    cp "$RELEASE/$ARCHIVE" "$RELEASE/$NEXT_ARCHIVE"
    (cd "$RELEASE" && sum256 "$NEXT_ARCHIVE" >> checksums.txt)
    SUDO_FAIL="$WORK/shim-sudo-fail"
    mkdir -p "$SUDO_FAIL"
    printf '#!/bin/sh\nexit 1\n' > "$SUDO_FAIL/sudo"
    chmod +x "$SUDO_FAIL/sudo"
    RO_BINS_BEFORE="$(cat "$RO_BIN/activity-log" "$RO_BIN/activity-watcher" "$RO_BIN/activity-mesh-daemon" | cksum)"
    RO_CURRENT_BEFORE="$(readlink "$RO_STORE/dist/current")"
    RO_CONFIG_BEFORE="$(cksum < "$RO_STORE/config.json")"
    chmod 555 "$RO_BIN"
    HOME="$RO_HOME" PREFIX="$RO_BIN" PATH="$SUDO_FAIL:$PATH" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
        bash "$BOOTSTRAP" --version v9.9.9 --no-services > "$WORK/bootstrap-ro2.out" 2>&1 && RC_RO2=0 || RC_RO2=$?
    chmod 755 "$RO_BIN"
    [ "$RC_RO2" -ne 0 ] || fail "bootstrap must fail when sudo is refused for a read-only prefix"
    [ "$(readlink "$RO_STORE/dist/current")" = "$RO_CURRENT_BEFORE" ] \
        || fail "dist/current switched to $(readlink "$RO_STORE/dist/current") although the binaries could not be installed"
    [ "$(cat "$RO_BIN/activity-log" "$RO_BIN/activity-watcher" "$RO_BIN/activity-mesh-daemon" | cksum)" = "$RO_BINS_BEFORE" ] \
        || fail "binaries changed by a refused install"
    [ "$(cksum < "$RO_STORE/config.json")" = "$RO_CONFIG_BEFORE" ] || fail "config.json changed by a refused install"
    [ ! -e "$RO_STORE/dist/9.9.9" ] || fail "assets or units of the refused version were installed"
    [ -z "$(find "$RO_BIN" -name '.*.new' 2>/dev/null)" ] || fail "staged binaries left behind: $(find "$RO_BIN" -name '.*.new')"
    pass "a refused sudo for a read-only prefix changes nothing"
fi

echo "== a failure after staging leaves no staged binaries behind =="
BAD_STAGE="$WORK/stage-bad"
cp -R "$STAGE" "$BAD_STAGE"
rm "$BAD_STAGE/registries/scopes.yaml"
for b in activity-log activity-watcher activity-mesh-daemon; do
    printf '#!/bin/sh\necho "%s 0.0.8"\n' "$b" > "$BAD_STAGE/$b"
done
BAD_ARCHIVE="activity-mesh_0.0.8_${OS}_${ARCH}.tar.gz"
(cd "$BAD_STAGE" && tar -czf "$RELEASE/$BAD_ARCHIVE" .)
(cd "$RELEASE" && sum256 "$BAD_ARCHIVE" >> checksums.txt)
BINS_BEFORE="$(cat "$PREFIX_DIR/activity-log" "$PREFIX_DIR/activity-watcher" "$PREFIX_DIR/activity-mesh-daemon" | cksum)"
CURRENT_BEFORE="$(readlink "$FAKE_HOME/.local/share/activity-mesh/dist/current")"
HOME="$FAKE_HOME" PREFIX="$PREFIX_DIR" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version v0.0.8 --no-services > "$WORK/bootstrap-bad.out" 2>&1 && RC_BAD=0 || RC_BAD=$?
[ "$RC_BAD" -ne 0 ] || fail "bootstrap must fail when an asset is missing after copy"
grep -q "required asset missing" "$WORK/bootstrap-bad.out" || fail "unexpected failure: $(tail -2 "$WORK/bootstrap-bad.out")"
[ -z "$(find "$PREFIX_DIR" -name '.*.new' 2>/dev/null)" ] || fail "staged binaries left behind: $(find "$PREFIX_DIR" -name '.*.new')"
[ "$(cat "$PREFIX_DIR/activity-log" "$PREFIX_DIR/activity-watcher" "$PREFIX_DIR/activity-mesh-daemon" | cksum)" = "$BINS_BEFORE" ] \
    || fail "binaries changed by a failed install"
[ "$(readlink "$FAKE_HOME/.local/share/activity-mesh/dist/current")" = "$CURRENT_BEFORE" ] || fail "dist/current switched by a failed install"
pass "a failure after staging leaves no staged binaries behind"

echo "== a re-run keeps the configured sync dir =="
CUSTOM_SYNC="$FAKE_HOME/Dropbox/activity"
HOME="$FAKE_HOME" "$PREFIX_DIR/activity-log" init --sync-dir "$CUSTOM_SYNC" --yes >/dev/null
HOME="$FAKE_HOME" PREFIX="$PREFIX_DIR" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-rerun.out" 2>&1 && RC_RERUN=0 || RC_RERUN=$?
[ "$RC_RERUN" -eq 0 ] || { cat "$WORK/bootstrap-rerun.out" >&2; fail "re-run exited $RC_RERUN"; }
grep -qF "\"sync_dir\": \"$CUSTOM_SYNC\"" "$FAKE_HOME/.local/share/activity-mesh/config.json" \
    || fail "re-run reset sync_dir: $(tr -d '\n' < "$FAKE_HOME/.local/share/activity-mesh/config.json")"
grep -rqF "$CUSTOM_SYNC" "$UNITS_DIR" || fail "units re-rendered without the configured sync dir"
[ -f "$CUSTOM_SYNC/kinds.yaml" ] || fail "registries not seeded into the configured sync dir"
pass "a re-run keeps the configured sync dir"

echo "== linux services path (supervisors shimmed, USER unset) =="
SHIM="$WORK/shim"
UNAME_SHIM="$WORK/shim-uname"
mkdir -p "$SHIM" "$UNAME_SHIM"
for c in systemctl loginctl launchctl sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$WORK/supervisor.log" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac\n' > "$UNAME_SHIM/uname"
chmod +x "$UNAME_SHIM/uname"
LINUX_ARCHIVE="activity-mesh_${VER}_linux_amd64.tar.gz"
if [ ! -f "$RELEASE/$LINUX_ARCHIVE" ]; then
    cp "$RELEASE/$ARCHIVE" "$RELEASE/$LINUX_ARCHIVE"
    (cd "$RELEASE" && sum256 "$LINUX_ARCHIVE" >> checksums.txt)
fi
LINUX_HOME="$WORK/home-linux"
mkdir -p "$LINUX_HOME/.local/bin"
printf '#!/bin/sh\necho "activity-log 0.0.1 (stale)"\n' > "$LINUX_HOME/.local/bin/activity-log"
chmod +x "$LINUX_HOME/.local/bin/activity-log"
env -u USER HOME="$LINUX_HOME" PREFIX="$WORK/bin-linux" PATH="$UNAME_SHIM:$SHIM:$PATH" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" > "$WORK/bootstrap-linux.out" 2>&1 && RC_LINUX=0 || RC_LINUX=$?
[ "$RC_LINUX" -eq 0 ] || { cat "$WORK/bootstrap-linux.out" >&2; fail "linux services install exited $RC_LINUX"; }
for unit in watcher daemon; do
    grep -qx "systemctl --user restart activity-mesh-$unit.service" "$WORK/supervisor.log" \
        || fail "activity-mesh-$unit.service not restarted: $(tr '\n' ';' < "$WORK/supervisor.log")"
done
pass "linux install restarts both units, so an upgrade runs the new binaries"
grep -qx "loginctl enable-linger $(id -un)" "$WORK/supervisor.log" || fail "enable-linger not called for $(id -un) with USER unset"
pass "linux install works with USER unset"
grep -qxF "Environment=ACTIVITY_MESH_BIN=$WORK/bin-linux/activity-log" "$LINUX_HOME/.config/systemd/user/activity-mesh-watcher.service" \
    || fail "systemd watcher unit must point ACTIVITY_MESH_BIN at the installed CLI"
grep -q "another activity-log at ~/.local/bin shadows" "$WORK/bootstrap-linux.out" \
    || fail "no warning about the stale ~/.local/bin/activity-log"
pass "systemd watcher unit carries ACTIVITY_MESH_BIN; a stale ~/.local/bin/activity-log is flagged"

if [ "$OS" = "darwin" ]; then
    echo "== macOS services path (launchctl shimmed) =="
    : > "$WORK/supervisor.log"
    MAC_HOME="$WORK/home-mac"
    mkdir -p "$MAC_HOME"
    HOME="$MAC_HOME" PREFIX="$WORK/bin-mac" PATH="$SHIM:$PATH" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
        bash "$BOOTSTRAP" --version "v$VER" > "$WORK/bootstrap-mac.out" 2>&1 && RC_MAC=0 || RC_MAC=$?
    [ "$RC_MAC" -eq 0 ] || { cat "$WORK/bootstrap-mac.out" >&2; fail "macOS services install exited $RC_MAC"; }
    BOOTED=$(grep -c "^launchctl bootstrap gui/$(id -u) $MAC_HOME/Library/LaunchAgents/com\.activity-mesh\." "$WORK/supervisor.log" || true)
    [ "$BOOTED" -eq 6 ] || fail "expected 6 launchd units bootstrapped from ~/Library/LaunchAgents, got $BOOTED"
    pass "macOS install renders into ~/Library/LaunchAgents and bootstraps all 6 units"
fi

echo "== ACTIVITY_MESH_HOME / ACTIVITY_MESH_STATE steer bootstrap and the binaries alike =="
ENV_HOME="$WORK/home-env"
mkdir -p "$ENV_HOME"
ACTIVITY_MESH_HOME="$WORK/env-store" ACTIVITY_MESH_STATE="$WORK/env-state" \
    HOME="$ENV_HOME" PREFIX="$WORK/bin-env" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-env.out" 2>&1 && RC_ENV=0 || RC_ENV=$?
[ "$RC_ENV" -eq 0 ] || { cat "$WORK/bootstrap-env.out" >&2; fail "bootstrap with ACTIVITY_MESH_HOME/STATE exited $RC_ENV"; }
[ -L "$WORK/env-store/dist/current" ] || fail "runtime assets not installed under ACTIVITY_MESH_HOME"
grep -qF "\"store_dir\": \"$WORK/env-store\"" "$WORK/env-store/config.json" 2>/dev/null \
    || fail "activity-log init did not write config.json under ACTIVITY_MESH_HOME"
[ ! -e "$ENV_HOME/.local/share/activity-mesh" ] || fail "bootstrap and the binaries disagree on the store dir"
[ -d "$WORK/env-state" ] || fail "ACTIVITY_MESH_STATE ignored"
pass "ACTIVITY_MESH_HOME / ACTIVITY_MESH_STATE steer bootstrap and the binaries alike"

echo "== an archive missing from checksums.txt fails with a diagnostic =="
cp "$RELEASE/$ARCHIVE" "$RELEASE/activity-mesh_0.0.9_${OS}_${ARCH}.tar.gz"
HOME="$WORK/home-nosum" PREFIX="$WORK/bin-nosum" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version v0.0.9 --no-services > "$WORK/bootstrap-nosum.out" 2>&1 && RC_NOSUM=0 || RC_NOSUM=$?
[ "$RC_NOSUM" -ne 0 ] || fail "bootstrap must fail when checksums.txt has no entry for the archive"
grep -q "no checksum entry for activity-mesh_0.0.9_${OS}_${ARCH}.tar.gz" "$WORK/bootstrap-nosum.out" \
    || fail "silent exit on a missing checksum entry: $(tail -2 "$WORK/bootstrap-nosum.out")"
pass "a missing checksum entry fails with a diagnostic"

echo "== a relative --prefix is made absolute =="
mkdir -p "$WORK/cwd" "$WORK/home-rel"
(cd "$WORK/cwd" && HOME="$WORK/home-rel" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --prefix ./relbin --no-services > "$WORK/bootstrap-rel.out" 2>&1) && RC_REL=0 || RC_REL=$?
[ "$RC_REL" -eq 0 ] || { cat "$WORK/bootstrap-rel.out" >&2; fail "bootstrap with a relative --prefix exited $RC_REL"; }
REL_UNITS="$(nosvc_units "$WORK/home-rel")"
DAEMON_REF="$(grep -rhoE '[^ >=]*relbin/activity-mesh-daemon' "$REL_UNITS" 2>/dev/null | head -1 || true)"
case "$DAEMON_REF" in
    /*) [ -x "$DAEMON_REF" ] || fail "units point at $DAEMON_REF, which is not the installed daemon" ;;
    "") fail "no unit in $REL_UNITS references the daemon" ;;
    *) fail "relative --prefix leaked into the units: '$DAEMON_REF'" ;;
esac
pass "a relative --prefix is made absolute"

echo "== curl | bash shape (script on stdin) =="
PIPE_OUT="$(HOME="$WORK/home-pipe" bash -s -- --dry-run < "$BOOTSTRAP" 2>&1)" || fail "stdin dry-run failed: $PIPE_OUT"
if printf '%s\n' "$PIPE_OUT" | grep -q "unbound variable"; then
    fail "stdin run trips set -u: $(printf '%s\n' "$PIPE_OUT" | grep "unbound variable")"
fi
pass "the script runs from stdin"

echo "== & and \\ in substituted values survive template rendering =="
ODD_HOME="$WORK/home-r&d\\x"
mkdir -p "$ODD_HOME"
HOME="$ODD_HOME" PREFIX="$WORK/bin-odd" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-odd.out" 2>&1 && RC_ODD=0 || RC_ODD=$?
[ "$RC_ODD" -eq 0 ] || { cat "$WORK/bootstrap-odd.out" >&2; fail "bootstrap with & and \\ in HOME exited $RC_ODD"; }
grep -rqF "$ODD_HOME/Sync/activity" "$(nosvc_units "$ODD_HOME")" || fail "template rendering mangled a path holding & or \\"
pass "& and \\ in substituted values survive template rendering"
ODD_CONFIG="$ODD_HOME/.local/share/activity-mesh/config.json"
ODD_CONFIG_BEFORE="$(cksum < "$ODD_CONFIG")"
HOME="$ODD_HOME" PREFIX="$WORK/bin-odd" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-odd2.out" 2>&1 && RC_ODD2=0 || RC_ODD2=$?
[ "$RC_ODD2" -eq 0 ] || { cat "$WORK/bootstrap-odd2.out" >&2; fail "re-run with & and \\ in the sync dir exited $RC_ODD2"; }
[ "$(cksum < "$ODD_CONFIG")" = "$ODD_CONFIG_BEFORE" ] || fail "re-run moved the configured sync dir: $(tr -d '\n' < "$ODD_CONFIG")"
grep -rqF "$ODD_HOME/Sync/activity" "$(nosvc_units "$ODD_HOME")" || fail "re-run rendered the units with a different sync dir"
pass "a re-run keeps a sync dir holding & and \\"

echo "== an undecodable sync_dir stops bootstrap and names ACTIVITY_MESH_SYNC =="
ESC_STORE="$WORK/home-esc/.local/share/activity-mesh"
mkdir -p "$ESC_STORE"
printf '{\n  "sync_dir": "%s/esc\\tsync",\n  "store_dir": "%s"\n}\n' "$WORK" "$ESC_STORE" > "$ESC_STORE/config.json"
HOME="$WORK/home-esc" PREFIX="$WORK/bin-esc" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services > "$WORK/bootstrap-esc.out" 2>&1 && RC_ESC=0 || RC_ESC=$?
[ "$RC_ESC" -ne 0 ] || fail "bootstrap must stop on a sync_dir it cannot decode"
grep -q "ACTIVITY_MESH_SYNC" "$WORK/bootstrap-esc.out" || fail "no hint to set ACTIVITY_MESH_SYNC: $(tail -2 "$WORK/bootstrap-esc.out")"
[ ! -e "$WORK/bin-esc" ] || fail "binaries installed despite an undecodable sync_dir"
pass "an undecodable sync_dir stops bootstrap and names ACTIVITY_MESH_SYNC"

echo "== corrupted checksum must fail hard =="
python3 - "$RELEASE/checksums.txt" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
p.write_text("0" * 64 + t[64:])
PYEOF
FAKE_HOME2="$WORK/home2"
mkdir -p "$FAKE_HOME2"
set +e
HOME="$FAKE_HOME2" PREFIX="$WORK/bin2" \
    ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" --no-services \
    > "$WORK/bootstrap2.out" 2>&1
RC2=$?
set -e
[ "$RC2" -ne 0 ] || fail "bootstrap must fail on checksum mismatch"
grep -q "MISMATCH" "$WORK/bootstrap2.out" || fail "no checksum-mismatch diagnostics"
if grep -q "bootstrap complete" "$WORK/bootstrap2.out"; then
    fail "'bootstrap complete' printed after a failed install"
fi
pass "checksum mismatch fails hard with no 'complete' banner"

echo
echo "ALL INSTALL TESTS PASSED"
