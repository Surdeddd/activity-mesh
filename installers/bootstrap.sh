#!/usr/bin/env bash
set -euo pipefail

REPO="${ACTIVITY_MESH_REPO:-Surdeddd/activity-mesh}"
VERSION="${VERSION:-latest}"
PREFIX="${PREFIX:-/usr/local/bin}"
BASE_URL="${ACTIVITY_MESH_BASE_URL:-}"
DRY_RUN=0
NO_SERVICES=0
LOCAL_MODE=0
REQUIRE_SIG=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)           DRY_RUN=1; shift ;;
        --version)           VERSION="$2"; shift 2 ;;
        --prefix)            PREFIX="$2"; shift 2 ;;
        --no-services)       NO_SERVICES=1; shift ;;
        --local)             LOCAL_MODE=1; shift ;;
        --require-signature) REQUIRE_SIG=1; shift ;;
        -h|--help)
            echo "usage: bootstrap.sh [--dry-run] [--version vX.Y.Z] [--prefix DIR] [--no-services] [--local] [--require-signature]"
            exit 0 ;;
        *) printf '\033[31m✗\033[0m unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[34m'; N='\033[0m'
else G=''; R=''; Y=''; B=''; N=''; fi
ok()   { printf '%b✓%b %s\n' "$G" "$N" "$*" >&2; }
warn() { printf '%b⚠%b %s\n' "$Y" "$N" "$*" >&2; }
info() { printf '%bi%b %s\n' "$B" "$N" "$*" >&2; }
die()  { printf '%b✗%b %s\n' "$R" "$N" "$*" >&2; printf '%b✗%b bootstrap FAILED — installation is incomplete\n' "$R" "$N" >&2; exit 1; }

case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *) die "unsupported OS: $(uname -s) (Windows: use installers/bootstrap.ps1 — CLI only)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac
HOST="$(hostname -s 2>/dev/null || hostname)"
info "host=$HOST os=$OS arch=$ARCH version=$VERSION dry_run=$DRY_RUN local=$LOCAL_MODE no_services=$NO_SERVICES"

LOG_BIN="$PREFIX/activity-log"
WATCHER_BIN="$PREFIX/activity-watcher"
DAEMON_BIN="$PREFIX/activity-mesh-daemon"
STORE_DIR="$HOME/.local/share/activity-mesh"
STATE_DIR="$HOME/.local/state/activity-mesh"
SYNC_DIR="${ACTIVITY_MESH_SYNC:-$HOME/Sync/activity}"
CONFIG_DIR="$HOME/.config/activity-mesh"
ASSETS_ROOT="$STORE_DIR/dist"
ASSETS_LINK="$ASSETS_ROOT/current"
TELEGRAM_ENV="${TELEGRAM_ENV:-$CONFIG_DIR/telegram.env}"

ensure_prefix() {
    [[ -d "$PREFIX" ]] && return 0
    mkdir -p "$PREFIX" 2>/dev/null && return 0
    info "elevating: sudo mkdir -p $PREFIX"
    sudo mkdir -p "$PREFIX" || die "cannot create prefix dir $PREFIX"
}

install_bin() {
    local src="$1" dest="$2"
    ensure_prefix
    if [[ ! -w "$(dirname "$dest")" ]]; then
        info "elevating: sudo install -m 0755 $src $dest"
        sudo install -m 0755 "$src" "$dest" || die "install $dest failed"
    else
        install -m 0755 "$src" "$dest" || die "install $dest failed"
    fi
    ok "binary installed → $dest"
}

verify_signature() {
    local dir="$1" base="$2"
    if ! command -v cosign >/dev/null 2>&1; then
        [[ $REQUIRE_SIG -eq 1 ]] && die "--require-signature set but cosign is not installed"
        info "signature NOT verified (cosign not installed); sha256 checksum was verified"
        return 0
    fi
    curl -fsSL "$base/checksums.txt.sig" -o "$dir/checksums.txt.sig" 2>/dev/null || {
        [[ $REQUIRE_SIG -eq 1 ]] && die "signature file missing from release"
        info "signature NOT verified (no .sig in release); sha256 checksum was verified"
        return 0
    }
    curl -fsSL "$base/checksums.txt.pem" -o "$dir/checksums.txt.pem" 2>/dev/null || {
        [[ $REQUIRE_SIG -eq 1 ]] && die "certificate file missing from release"
        info "signature NOT verified (no .pem in release); sha256 checksum was verified"
        return 0
    }
    if cosign verify-blob \
        --certificate "$dir/checksums.txt.pem" \
        --signature "$dir/checksums.txt.sig" \
        --certificate-identity-regexp "^https://github.com/${REPO}/" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$dir/checksums.txt" >/dev/null 2>&1; then
        ok "cosign signature verified (checksums.txt)"
    else
        die "cosign signature verification FAILED for checksums.txt"
    fi
}

RELEASE_DIR=""
RESOLVED_VERSION=""

install_release() {
    command -v curl >/dev/null 2>&1 || die "curl required"
    local tag="$VERSION"
    if [[ -z "$BASE_URL" ]]; then
        if [[ "$tag" == "latest" ]]; then
            tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
                    | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
            [[ -n "$tag" ]] || die "cannot resolve latest release tag from GitHub API"
        fi
        BASE_URL="https://github.com/${REPO}/releases/download/${tag}"
    else
        [[ "$tag" != "latest" ]] || die "ACTIVITY_MESH_BASE_URL requires an explicit --version"
    fi
    RESOLVED_VERSION="${tag#v}"
    local archive="activity-mesh_${RESOLVED_VERSION}_${OS}_${ARCH}.tar.gz"
    local tmp; tmp="$(mktemp -d)"
    info "fetching $BASE_URL/$archive"
    curl -fsSL "$BASE_URL/$archive"      -o "$tmp/$archive"      || die "archive download failed: $archive"
    curl -fsSL "$BASE_URL/checksums.txt" -o "$tmp/checksums.txt" || die "checksums.txt download failed"
    local want got
    want="$(grep " $archive\$" "$tmp/checksums.txt" | awk '{print $1}')"
    [[ -n "$want" ]] || die "no checksum entry for $archive"
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
    else got="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"; fi
    [[ "$want" == "$got" ]] || die "checksum MISMATCH for $archive (want $want got $got)"
    ok "sha256 verified ($archive)"
    verify_signature "$tmp" "$BASE_URL"
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/$archive" -C "$tmp/x" || die "archive extraction failed"
    for b in activity-log activity-watcher activity-mesh-daemon; do
        [[ -f "$tmp/x/$b" ]] || die "$b missing from release archive"
        install_bin "$tmp/x/$b" "$PREFIX/$b"
    done
    RELEASE_DIR="$tmp/x"
}

install_local() {
    local root="$SCRIPT_DIR/.."
    [[ -f "$root/health/master.sh" ]] || die "--local requires a repo checkout (health/master.sh not found next to installers/)"
    RESOLVED_VERSION="$(tr -d '[:space:]' < "$root/VERSION" 2>/dev/null || echo dev)-local"
    RELEASE_DIR="$(cd "$root" && pwd)"
    # Private build dir: a predictable /tmp path lets any local user pre-create
    # the target and have `install_bin` (often sudo) install their binary.
    local build
    build="$(mktemp -d "${TMPDIR:-/tmp}/am-bootstrap-build.XXXXXX")" || die "mktemp failed"
    trap 'rm -rf "$build"' RETURN
    # Rebuild first, keep-existing only as a fallback. The other order made
    # --local a no-op for binaries while still re-pointing dist/current and
    # re-rendering every unit: assets at version N, binaries at N-1, and a green
    # "bootstrap complete ... version N" banner. bootstrap IS the upgrade path.
    for b in activity-log activity-watcher activity-mesh-daemon; do
        if command -v go >/dev/null 2>&1; then
            local src="./cmd/$b"
            [[ "$b" == "activity-mesh-daemon" ]] && src="./server"
            info "building $b from source"
            (cd "$RELEASE_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$RESOLVED_VERSION" -o "$build/$b" "$src") || die "go build $b failed"
            install_bin "$build/$b" "$PREFIX/$b"
        elif [[ -x "$PREFIX/$b" ]]; then
            warn "no Go toolchain — keeping existing $PREFIX/$b (may be older than $RESOLVED_VERSION)"
        else
            die "$b not in $PREFIX and Go toolchain unavailable"
        fi
    done
}

install_assets() {
    local src="$1"
    local dest="$ASSETS_ROOT/$RESOLVED_VERSION"
    mkdir -p "$dest" || die "mkdir $dest failed"
    for d in installers health registries configs hooks; do
        [[ -d "$src/$d" ]] || die "required asset dir missing from source: $d"
        rm -rf "${dest:?}/$d"
        cp -R "$src/$d" "$dest/$d" || die "copy $d failed"
    done
    if [[ -d "$src/mcp" ]]; then
        rm -rf "${dest:?}/mcp"
        cp -R "$src/mcp" "$dest/mcp" || die "copy mcp failed"
    fi
    for f in VERSION README.md CHANGELOG.md LICENSE; do
        [[ -f "$src/$f" ]] && cp "$src/$f" "$dest/$f"
    done
    for req in \
        "$dest/health/master.sh" \
        "$dest/health/lib.sh" \
        "$dest/health/dead-man-heartbeat.sh" \
        "$dest/health/weekly-digest.sh" \
        "$dest/configs/watcher.yaml" \
        "$dest/registries/kinds.yaml" \
        "$dest/registries/scopes.yaml" \
        "$dest/registries/agents.yaml" \
        "$dest/registries/redaction.yaml" \
        "$dest/installers/templates/launchd-daemon.plist.tmpl" \
        "$dest/installers/templates/systemd-daemon.service.tmpl"; do
        [[ -f "$req" ]] || die "required asset missing after install: $req"
    done
    [[ -n "$(ls "$dest/health/checks/" 2>/dev/null)" ]] || die "health/checks is empty in installed assets"
    ln -sfn "$dest" "$ASSETS_LINK" || die "cannot update $ASSETS_LINK symlink"
    ok "runtime assets installed → $dest (current → $ASSETS_LINK)"
}

render_template() {
    local tmpl="$1" dest="$2"
    [[ -f "$tmpl" ]] || die "template not found: $tmpl"
    local c; c="$(cat "$tmpl")"
    c="${c//\{\{BIN_PATH\}\}/$LOG_BIN}"
    c="${c//\{\{WATCHER_BIN\}\}/$WATCHER_BIN}"
    c="${c//\{\{DAEMON_BIN\}\}/$DAEMON_BIN}"
    c="${c//\{\{STORE_DIR\}\}/$STORE_DIR}"
    c="${c//\{\{STATE_DIR\}\}/$STATE_DIR}"
    c="${c//\{\{SYNC_DIR\}\}/$SYNC_DIR}"
    c="${c//\{\{CONFIG_DIR\}\}/$CONFIG_DIR}"
    c="${c//\{\{TELEGRAM_ENV\}\}/$TELEGRAM_ENV}"
    c="${c//\{\{ASSETS_DIR\}\}/$ASSETS_LINK}"
    c="${c//\{\{HOME\}\}/$HOME}"
    c="${c//\{\{USER\}\}/${USER:-$(id -un)}}"
    if printf '%s' "$c" | grep -q '{{[A-Z_]*}}'; then
        die "unresolved placeholder in $tmpl: $(printf '%s' "$c" | grep -o '{{[A-Z_]*}}' | sort -u | tr '\n' ' ')"
    fi
    printf '%s\n' "$c" > "$dest" || die "write $dest failed"
}

install_macos_units() {
    local agents="$HOME/Library/LaunchAgents"
    mkdir -p "$agents" || die "mkdir $agents failed"
    local tdir="$ASSETS_LINK/installers/templates"
    for unit in watcher daemon health heartbeat compact weekly-digest; do
        local plist="$agents/com.activity-mesh.${unit}.plist"
        render_template "$tdir/launchd-${unit}.plist.tmpl" "$plist"
        ok "rendered $plist"
        if [[ $NO_SERVICES -eq 1 ]]; then
            info "skip launchctl (--no-services): com.activity-mesh.${unit}"
            continue
        fi
        launchctl bootout "gui/$(id -u)/com.activity-mesh.${unit}" 2>/dev/null || true
        local booted=0 lc_err=""
        for _ in 1 2 3; do
            if lc_err="$(launchctl bootstrap "gui/$(id -u)" "$plist" 2>&1)"; then
                booted=1
                break
            fi
            sleep 2
        done
        [[ $booted -eq 1 ]] || die "launchctl bootstrap failed for com.activity-mesh.${unit}: $lc_err"
        ok "launchd bootstrapped com.activity-mesh.${unit}"
        case "$unit" in
            watcher|daemon)
                if launchctl kickstart "gui/$(id -u)/com.activity-mesh.${unit}" 2>/dev/null; then
                    ok "launchd kickstarted com.activity-mesh.${unit}"
                else
                    warn "launchctl kickstart failed for com.activity-mesh.${unit} — unit waits for launchd"
                fi
                ;;
        esac
    done
}

install_linux_units() {
    local user_dir="$HOME/.config/systemd/user"
    mkdir -p "$user_dir" || die "mkdir $user_dir failed"
    local tdir="$ASSETS_LINK/installers/templates"
    for unit in watcher daemon; do
        local svc="$user_dir/activity-mesh-${unit}.service"
        render_template "$tdir/systemd-${unit}.service.tmpl" "$svc"
        ok "rendered $svc"
        if [[ $NO_SERVICES -eq 1 ]]; then
            info "skip systemctl (--no-services): activity-mesh-${unit}"
            continue
        fi
        systemctl --user daemon-reload || die "systemctl daemon-reload failed"
        systemctl --user enable --now "activity-mesh-${unit}.service" \
            || die "systemctl enable failed for activity-mesh-${unit}"
        ok "systemd enabled+started activity-mesh-${unit}"
    done
    info "periodic jobs (health/heartbeat/compact/weekly-digest) run from $ASSETS_LINK/health/ — schedule them with systemd timers or cron (see installers/README.md)"
    if [[ $NO_SERVICES -eq 0 ]]; then
        loginctl enable-linger "$USER" 2>/dev/null \
            || warn "enable-linger failed (services pause when logged out)"
    fi
}

if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY: would download release ($OS/$ARCH), verify sha256 (+cosign when available), install 3 binaries to $PREFIX"
    info "DRY: would install runtime assets to $ASSETS_ROOT/<version> and point $ASSETS_LINK at it"
    info "DRY: would scaffold $STORE_DIR $STATE_DIR $SYNC_DIR $CONFIG_DIR"
    info "DRY: would seed registries to $SYNC_DIR and watcher.yaml to $CONFIG_DIR"
    if [[ "$OS" == "darwin" ]]; then
        info "DRY: would render+bootstrap 6 launchd units (watcher daemon health heartbeat compact weekly-digest)"
    else
        info "DRY: would render+enable 2 systemd user units (watcher daemon)"
    fi
    info "this was a dry-run — re-run without --dry-run to apply"
    exit 0
fi

if [[ $LOCAL_MODE -eq 1 ]]; then
    install_local
else
    install_release
fi

for d in "$STORE_DIR" "$STATE_DIR" "$SYNC_DIR" "$CONFIG_DIR"; do
    mkdir -p "$d" || die "mkdir $d failed"
    ok "dir $d"
done

install_assets "$RELEASE_DIR"

if [[ ! -f "$CONFIG_DIR/watcher.yaml" ]]; then
    cp "$ASSETS_LINK/configs/watcher.yaml" "$CONFIG_DIR/watcher.yaml" || die "install watcher.yaml failed"
    ok "installed default watcher.yaml"
fi

for reg in kinds scopes agents redaction; do
    if [[ ! -f "$SYNC_DIR/$reg.yaml" ]]; then
        cp "$ASSETS_LINK/registries/$reg.yaml" "$SYNC_DIR/$reg.yaml" || die "seed $reg.yaml failed"
        ok "seeded registry → $SYNC_DIR/$reg.yaml"
    fi
done

"$LOG_BIN" init --sync-dir "$SYNC_DIR" --yes || die "activity-log init failed"
"$LOG_BIN" refresh-caches || warn "refresh-caches returned non-zero (router caches will refresh hourly)"

if [[ "$OS" == "darwin" ]]; then install_macos_units; else install_linux_units; fi

"$LOG_BIN" --version || die "installed activity-log does not run"
# Catch asset/binary skew: dist/current now points at $RESOLVED_VERSION, so a
# binary reporting anything else means the install left a stale one behind.
"$LOG_BIN" --version 2>/dev/null | grep -qF -- "$RESOLVED_VERSION" \
    || warn "binary version differs from installed assets ($RESOLVED_VERSION) — stale binary in $PREFIX?"
"$LOG_BIN" status || die "activity-log status failed"
"$LOG_BIN" emit --kind status --scope activity-mesh --summary "installed on $HOST" >/dev/null \
    || die "smoke emit failed"
ok "verification done"

ok "bootstrap complete on ${HOST} (${OS}/${ARCH}, version ${RESOLVED_VERSION})"
