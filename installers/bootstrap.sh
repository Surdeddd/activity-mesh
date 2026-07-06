#!/usr/bin/env bash
# activity-mesh bootstrap (macOS + Linux)
# Re-running upgrades binaries; preserves config + state.
# Usage: bash bootstrap.sh [--dry-run] [--version vX.Y.Z] [--prefix DIR]
set -euo pipefail

REPO="${ACTIVITY_MESH_REPO:-Surdeddd/activity-mesh}"
VERSION="${VERSION:-latest}"
PREFIX="${PREFIX:-/usr/local/bin}"
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        --prefix)  PREFIX="$2";  shift 2 ;;
        -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
        *) printf '\033[31m✗\033[0m unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[34m'; N='\033[0m'
else G=''; R=''; Y=''; B=''; N=''; fi
ok()   { printf '%b✓%b %s\n' "$G" "$N" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$R" "$N" "$*" >&2; }
warn() { printf '%b⚠%b %s\n' "$Y" "$N" "$*" >&2; }
info() { printf '%bi%b %s\n' "$B" "$N" "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; else eval "$*"; fi; }

# ---- detect OS / arch ------------------------------------------------------
case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *) err "unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) err "unsupported arch: $(uname -m)"; exit 1 ;;
esac
HOST="$(hostname -s 2>/dev/null || hostname)"
info "host=$HOST os=$OS arch=$ARCH version=$VERSION dry_run=$DRY_RUN"

# ---- paths -----------------------------------------------------------------
# Two dirs, no third (see the template header comment):
#   STORE = ~/.local/share  index.db, cursors, seq, audit, config  (ACTIVITY_MESH_HOME)
#   STATE = ~/.local/state  logs, tokens, clock-offset, health/heartbeat state (ACTIVITY_MESH_STATE)
LOG_BIN="$PREFIX/activity-log"
WATCHER_BIN="$PREFIX/activity-watcher"
DAEMON_BIN="$PREFIX/activity-mesh-daemon"
STORE_DIR="$HOME/.local/share/activity-mesh"
STATE_DIR="$HOME/.local/state/activity-mesh"
SYNC_DIR="$HOME/Sync/activity"
CONFIG_DIR="$HOME/.config/activity-mesh"
# Telegram env file for alerts (override via env). am_notify also honours
# ACTIVITY_MESH_NOTIFY_CMD and TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID directly.
TELEGRAM_ENV="${TELEGRAM_ENV:-$CONFIG_DIR/telegram.env}"

# ---- 1. download + verify + install the release archive --------------------
# The release ships one archive per platform holding all three binaries, plus
# a signed checksums.txt. We verify sha256 before installing anything.
install_release() {
    if [[ $DRY_RUN -eq 1 ]]; then info "DRY: would download+verify+install $OS/$ARCH archive"; return 0; fi
    command -v curl >/dev/null 2>&1 || { err "curl required"; return 1; }
    local tag="$VERSION"
    if [[ "$tag" == "latest" ]]; then
        tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
                | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
        [[ -n "$tag" ]] || { warn "cannot resolve latest tag from GitHub API"; return 1; }
    fi
    local ver="${tag#v}"
    local archive="activity-mesh_${ver}_${OS}_${ARCH}.tar.gz"
    local base="https://github.com/${REPO}/releases/download/${tag}"
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    info "fetching $archive"
    curl -fsSL "$base/$archive"      -o "$tmp/$archive"      || { warn "archive download failed"; return 1; }
    curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" || { warn "checksums download failed"; return 1; }
    # verify sha256
    local want got
    want="$(grep " $archive\$" "$tmp/checksums.txt" | awk '{print $1}')"
    [[ -n "$want" ]] || { err "no checksum entry for $archive"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
    else got="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"; fi
    [[ "$want" == "$got" ]] || { err "checksum MISMATCH for $archive (want $want got $got)"; return 1; }
    ok "checksum verified ($archive)"
    tar -xzf "$tmp/$archive" -C "$tmp"
    for b in activity-log activity-watcher activity-mesh-daemon; do
        [[ -f "$tmp/$b" ]] || { warn "$b missing from archive"; continue; }
        install_bin "$tmp/$b" "$PREFIX/$b"
    done
}
install_bin() {
    local src="$1" dest="$2"
    if [[ ! -w "$(dirname "$dest")" ]]; then
        info "elevating: sudo install -m 0755 $src $dest"
        sudo install -m 0755 "$src" "$dest"
    else
        install -m 0755 "$src" "$dest"
    fi
    ok "binary installed → $dest"
}

if ! install_release; then
    warn "release install failed — build locally instead: make install (needs Go)"
fi

# ---- 2. scaffold directories ----------------------------------------------
for d in "$STORE_DIR" "$STATE_DIR" "$SYNC_DIR" "$CONFIG_DIR"; do
    if [[ -d "$d" ]]; then ok "exists $d"
    else run "mkdir -p \"$d\""; ok "mkdir $d"; fi
done

# copy default watcher.yaml if repo has one and target missing
if [[ -f "$SCRIPT_DIR/../configs/watcher.yaml" ]] && [[ ! -f "$CONFIG_DIR/watcher.yaml" ]]; then
    run "cp \"$SCRIPT_DIR/../configs/watcher.yaml\" \"$CONFIG_DIR/watcher.yaml\""
    ok "installed default watcher.yaml"
fi

# publish registries to the sync dir (canonical live location the CLI, the
# router cache generator, and schema-drift.sh all read). Never overwrite a
# live copy — only seed missing ones.
if [[ -d "$SCRIPT_DIR/../registries" ]]; then
    for reg in kinds scopes agents redaction; do
        src="$SCRIPT_DIR/../registries/$reg.yaml"
        dst="$SYNC_DIR/$reg.yaml"
        if [[ -f "$src" ]] && [[ ! -f "$dst" ]]; then
            run "cp \"$src\" \"$dst\""
            ok "seeded registry → $dst"
        fi
    done
fi

if command -v "$LOG_BIN" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    "$LOG_BIN" init --sync-dir "$SYNC_DIR" --yes 2>/dev/null \
        || warn "activity-log init returned non-zero"
    "$LOG_BIN" refresh-caches 2>/dev/null || warn "refresh-caches returned non-zero"
else
    info "skip 'activity-log init' (binary missing or dry-run)"
fi

# ---- 3. render + install supervisor units ---------------------------------
render_template() {
    local tmpl="$1" dest="$2"
    if [[ ! -f "$tmpl" ]]; then warn "template not found: $tmpl"; return 1; fi
    local c; c="$(cat "$tmpl")"
    c="${c//\{\{BIN_PATH\}\}/$LOG_BIN}"
    c="${c//\{\{WATCHER_BIN\}\}/$WATCHER_BIN}"
    c="${c//\{\{DAEMON_BIN\}\}/$DAEMON_BIN}"
    c="${c//\{\{STORE_DIR\}\}/$STORE_DIR}"
    c="${c//\{\{STATE_DIR\}\}/$STATE_DIR}"
    c="${c//\{\{SYNC_DIR\}\}/$SYNC_DIR}"
    c="${c//\{\{CONFIG_DIR\}\}/$CONFIG_DIR}"
    c="${c//\{\{TELEGRAM_ENV\}\}/$TELEGRAM_ENV}"
    c="${c//\{\{REPO_DIR\}\}/$(cd "$SCRIPT_DIR/.." && pwd)}"
    c="${c//\{\{HOME\}\}/$HOME}"
    c="${c//\{\{USER\}\}/${USER:-$(id -un)}}"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%bDRY%b would write %s (%d bytes)\n' "$Y" "$N" "$dest" "${#c}" >&2
    else printf '%s\n' "$c" > "$dest"; fi
}

# All units bootstrap knows about. watcher+daemon are long-running services;
# health/heartbeat/compact/weekly-digest are periodic (launchd StartInterval /
# systemd timers shipped as templates).
MAC_UNITS=(watcher daemon health heartbeat compact weekly-digest)

install_macos() {
    local agents="$HOME/Library/LaunchAgents"; run "mkdir -p \"$agents\""
    for unit in "${MAC_UNITS[@]}"; do
        local tmpl plist="$agents/com.activity-mesh.${unit}.plist"
        tmpl="$SCRIPT_DIR/templates/launchd-${unit}.plist.tmpl"
        render_template "$tmpl" "$plist" || continue
        ok "rendered $plist"
        if [[ $DRY_RUN -eq 0 ]]; then
            launchctl bootout "gui/$(id -u)/com.activity-mesh.${unit}" 2>/dev/null || true
            if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
                ok "launchd bootstrapped com.activity-mesh.${unit}"
            else warn "launchctl bootstrap failed for ${unit}"; fi
        else info "DRY: launchctl bootstrap gui/$(id -u) $plist"; fi
    done
}

install_linux() {
    local user_dir="$HOME/.config/systemd/user"; run "mkdir -p \"$user_dir\""
    # long-running services
    for unit in watcher daemon; do
        local svc="$user_dir/activity-mesh-${unit}.service"
        render_template "$SCRIPT_DIR/templates/systemd-${unit}.service.tmpl" "$svc" || continue
        ok "rendered $svc"
        if [[ $DRY_RUN -eq 0 ]]; then
            systemctl --user daemon-reload || warn "daemon-reload failed"
            if systemctl --user enable --now "activity-mesh-${unit}.service"; then
                ok "systemd enabled+started activity-mesh-${unit}"
            else warn "systemctl enable failed for ${unit}"; fi
        else info "DRY: systemctl --user enable --now activity-mesh-${unit}"; fi
    done
    warn "periodic jobs (health/heartbeat/compact/weekly-digest): add systemd timers or cron — see installers/README.md"
    if [[ $DRY_RUN -eq 0 ]]; then
        loginctl enable-linger "$USER" 2>/dev/null \
            || warn "enable-linger failed (services pause when logged out)"
    fi
}

[[ "$OS" == "darwin" ]] && install_macos
[[ "$OS" == "linux"  ]] && install_linux

# ---- 4. verify -------------------------------------------------------------
if command -v "$LOG_BIN" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    info "running: $LOG_BIN --version"
    "$LOG_BIN" --version 2>/dev/null || true
    "$LOG_BIN" status || warn "status returned non-zero"
    "$LOG_BIN" emit --kind status --scope activity-mesh \
        --summary "installed on $HOST" || warn "smoke emit failed"
    ok "verification done"
else info "skip verify (binary missing or dry-run)"; fi

ok "bootstrap complete on ${HOST} (${OS}/${ARCH})"
[[ $DRY_RUN -eq 1 ]] && info "this was a dry-run — re-run without --dry-run to apply"
