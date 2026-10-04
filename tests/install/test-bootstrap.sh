#!/usr/bin/env bash
set -euo pipefail

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
    bash "$REPO_ROOT/installers/bootstrap.sh" --version "v$VER" --no-services \
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
pass "3 binaries installed"

ASSETS="$FAKE_HOME/.local/share/activity-mesh/dist/$VER"
for req in health/master.sh health/lib.sh configs/watcher.yaml registries/kinds.yaml hooks/user-prompt-router.sh mcp/server.mjs installers/templates/launchd-daemon.plist.tmpl; do
    [ -f "$ASSETS/$req" ] || fail "asset missing: $ASSETS/$req"
done
[ -L "$FAKE_HOME/.local/share/activity-mesh/dist/current" ] || fail "current symlink missing"
pass "versioned runtime assets installed"

if [ "$OS" = "darwin" ]; then
    UNITS_DIR="$FAKE_HOME/Library/LaunchAgents"
    N_UNITS=6
else
    UNITS_DIR="$FAKE_HOME/.config/systemd/user"
    N_UNITS=2
fi
COUNT=$(find "$UNITS_DIR" -name "*activity-mesh*" 2>/dev/null | wc -l | tr -d " ")
[ "$COUNT" -eq "$N_UNITS" ] || fail "expected $N_UNITS rendered units, got $COUNT"
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

echo "== linux services path (supervisors shimmed) =="
SHIM="$WORK/shim"
mkdir -p "$SHIM"
for c in systemctl loginctl launchctl sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$WORK/supervisor.log" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac\n' > "$SHIM/uname"
chmod +x "$SHIM/uname"
LINUX_ARCHIVE="activity-mesh_${VER}_linux_amd64.tar.gz"
if [ ! -f "$RELEASE/$LINUX_ARCHIVE" ]; then
    cp "$RELEASE/$ARCHIVE" "$RELEASE/$LINUX_ARCHIVE"
    (cd "$RELEASE" && sum256 "$LINUX_ARCHIVE" >> checksums.txt)
fi
LINUX_HOME="$WORK/home-linux"
mkdir -p "$LINUX_HOME/.local/bin"
printf '#!/bin/sh\necho "activity-log 0.0.1 (stale)"\n' > "$LINUX_HOME/.local/bin/activity-log"
chmod +x "$LINUX_HOME/.local/bin/activity-log"
HOME="$LINUX_HOME" PREFIX="$WORK/bin-linux" PATH="$SHIM:$PATH" ACTIVITY_MESH_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$BOOTSTRAP" --version "v$VER" > "$WORK/bootstrap-linux.out" 2>&1 && RC_LINUX=0 || RC_LINUX=$?
[ "$RC_LINUX" -eq 0 ] || { cat "$WORK/bootstrap-linux.out" >&2; fail "linux services install exited $RC_LINUX"; }
for unit in watcher daemon; do
    grep -qx "systemctl --user restart activity-mesh-$unit.service" "$WORK/supervisor.log" \
        || fail "activity-mesh-$unit.service not restarted: $(tr '\n' ';' < "$WORK/supervisor.log")"
done
pass "linux install restarts both units, so an upgrade runs the new binaries"
grep -qxF "Environment=ACTIVITY_MESH_BIN=$WORK/bin-linux/activity-log" "$LINUX_HOME/.config/systemd/user/activity-mesh-watcher.service" \
    || fail "systemd watcher unit must point ACTIVITY_MESH_BIN at the installed CLI"
grep -q "another activity-log at ~/.local/bin shadows" "$WORK/bootstrap-linux.out" \
    || fail "no warning about the stale ~/.local/bin/activity-log"
pass "systemd watcher unit carries ACTIVITY_MESH_BIN; a stale ~/.local/bin/activity-log is flagged"

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
    bash "$REPO_ROOT/installers/bootstrap.sh" --version "v$VER" --no-services \
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
