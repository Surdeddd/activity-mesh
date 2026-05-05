#!/usr/bin/env bash
# activity-mesh bootstrap (macOS + Linux)
# Re-running upgrades binaries; preserves config + state.
# Usage: bash bootstrap.sh [--dry-run] [--version vX.Y.Z] [--prefix DIR]
set -euo pipefail

REPO="Surdeddd/activity-mesh"
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
LOG_BIN="$PREFIX/activity-log"
WATCHER_BIN="$PREFIX/activity-watcher"
STATE_DIR="$HOME/.local/share/activity-mesh"
LOG_DIR="$HOME/.local/log/activity-mesh"
SYNC_DIR="$HOME/Sync/activity"
CONFIG_DIR="$HOME/.config/activity-mesh"

# ---- 1. download + install binaries ----------------------------------------
fetch_bin() {
    # $1=binary basename (activity-log|activity-watcher); $2=destination path
    local name="$1" dest="$2"
    local asset="${name}-${OS}-${ARCH}"
    local tmp; tmp="$(mktemp)"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: would download $asset → $dest"; return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        local tag="$VERSION"; [[ "$tag" == "latest" ]] && tag=""
        if gh release download "$tag" --repo "$REPO" --pattern "$asset" --output "$tmp" 2>/dev/null; then
            install_bin "$tmp" "$dest"; return 0
        fi
        warn "gh download failed for $asset, falling back to curl"
    fi
    if ! command -v curl >/dev/null 2>&1; then err "neither gh nor curl available"; exit 1; fi
    local tagseg="latest"; [[ "$VERSION" != "latest" ]] && tagseg="$VERSION"
    local url="https://github.com/${REPO}/releases/${tagseg}/download/${asset}"
    info "fetching $url"
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
        warn "release not found at $url — skipping. Build locally: go build -o $dest ./cmd/${name}"
        rm -f "$tmp"; return 1
    fi
    install_bin "$tmp" "$dest"
}
install_bin() {
    local src="$1" dest="$2"
    if [[ ! -w "$(dirname "$dest")" ]]; then
        info "elevating: sudo install -m 0755 $src $dest"
        sudo install -m 0755 "$src" "$dest"
    else
        install -m 0755 "$src" "$dest"
    fi
    rm -f "$src"; ok "binary installed → $dest"
}

fetch_bin activity-log     "$LOG_BIN"     || warn "no activity-log binary; CLI smoke will be skipped"
fetch_bin activity-watcher "$WATCHER_BIN" || warn "no activity-watcher binary; watcher unit will fail until built"

# ---- 2. scaffold directories ----------------------------------------------
for d in "$STATE_DIR" "$LOG_DIR" "$SYNC_DIR" "$CONFIG_DIR"; do
    if [[ -d "$d" ]]; then ok "exists $d"
    else run "mkdir -p \"$d\""; ok "mkdir $d"; fi
done

# copy default watcher.yaml if repo has one and target missing
if [[ -f "$SCRIPT_DIR/../configs/watcher.yaml" ]] && [[ ! -f "$CONFIG_DIR/watcher.yaml" ]]; then
    run "cp \"$SCRIPT_DIR/../configs/watcher.yaml\" \"$CONFIG_DIR/watcher.yaml\""
    ok "installed default watcher.yaml"
fi

if command -v "$LOG_BIN" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    "$LOG_BIN" init --state "$STATE_DIR" --sync "$SYNC_DIR" 2>/dev/null \
        || warn "activity-log init returned non-zero (subcommand may not exist yet)"
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
    c="${c//\{\{STATE_DIR\}\}/$STATE_DIR}"
    c="${c//\{\{SYNC_DIR\}\}/$SYNC_DIR}"
    c="${c//\{\{CONFIG_DIR\}\}/$CONFIG_DIR}"
    c="${c//\{\{LOG_DIR\}\}/$LOG_DIR}"
    c="${c//\{\{HOME\}\}/$HOME}"
    c="${c//\{\{USER\}\}/${USER:-$(id -un)}}"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%bDRY%b would write %s (%d bytes)\n' "$Y" "$N" "$dest" "${#c}" >&2
    else printf '%s\n' "$c" > "$dest"; fi
}

install_macos() {
    local agents="$HOME/Library/LaunchAgents"; run "mkdir -p \"$agents\""
    for unit in watcher daemon; do
        local plist="$agents/com.activity-mesh.${unit}.plist"
        render_template "$SCRIPT_DIR/templates/launchd-${unit}.plist.tmpl" "$plist" || continue
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
    if [[ $DRY_RUN -eq 0 ]]; then
        loginctl enable-linger "$USER" 2>/dev/null \
            || warn "enable-linger failed (services pause when logged out)"
    fi
}

[[ "$OS" == "darwin" ]] && install_macos
[[ "$OS" == "linux"  ]] && install_linux

# ---- 4. verify -------------------------------------------------------------
if command -v "$LOG_BIN" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    info "running: $LOG_BIN status"
    "$LOG_BIN" status || warn "status returned non-zero"
    "$LOG_BIN" emit --kind status --scope bootstrap \
        --summary "installed on $HOST" || warn "smoke emit failed"
    ok "verification done"
else info "skip verify (binary missing or dry-run)"; fi

ok "bootstrap complete on ${HOST} (${OS}/${ARCH})"
[[ $DRY_RUN -eq 1 ]] && info "this was a dry-run — re-run without --dry-run to apply"
