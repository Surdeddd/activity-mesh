#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amesh-install-test.XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

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
(cd "$RELEASE" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$ARCHIVE" || shasum -a 256 "$ARCHIVE"; } > checksums.txt)

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

for reg in kinds scopes agents redaction; do
    [ -f "$FAKE_HOME/Sync/activity/$reg.yaml" ] || fail "registry not seeded: $reg.yaml"
done
[ -f "$FAKE_HOME/.config/activity-mesh/watcher.yaml" ] || fail "watcher.yaml not installed"
pass "registries + watcher.yaml seeded"

HOME="$FAKE_HOME" "$PREFIX_DIR/activity-log" query --since 24h --format text | grep -q "installed on" \
    || fail "smoke event not queryable"
pass "smoke emit is queryable"

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
