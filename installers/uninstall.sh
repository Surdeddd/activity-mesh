#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
PURGE=0
DRY_RUN=0
KEEP_DATA=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge|--no-keep-data) PURGE=1; KEEP_DATA=0; shift ;;
        --keep-data)            KEEP_DATA=1; PURGE=0; shift ;;
        --dry-run)              DRY_RUN=1; shift ;;
        --prefix)               PREFIX="$2"; shift 2 ;;
        -h|--help)              echo "usage: uninstall.sh [--purge] [--dry-run] [--prefix DIR]"; exit 0 ;;
        *) printf '\033[31m✗\033[0m unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    G='\033[32m'; R='\033[31m'; Y='\033[33m'; N='\033[0m'
else
    G=''; R=''; Y=''; N=''
fi
ok()   { printf '%b✓%b %s\n' "$G" "$N" "$*" >&2; }
warn() { printf '%b⚠%b %s\n' "$Y" "$N" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$R" "$N" "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; else eval "$*"; fi; }

UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *)      err "unsupported OS: $UNAME_S"; exit 1 ;;
esac

STORE_DIR="$HOME/.local/share/activity-mesh"
STATE_DIR="$HOME/.local/state/activity-mesh"
SYNC_DIR="$HOME/Sync/activity"
CONFIG_DIR="$HOME/.config/activity-mesh"

uninstall_macos() {
    local unit plist
    for unit in watcher daemon health heartbeat compact weekly-digest; do
        plist="$HOME/Library/LaunchAgents/com.activity-mesh.${unit}.plist"
        if [[ -f "$plist" || $DRY_RUN -eq 1 ]]; then
            run "launchctl bootout gui/$(id -u)/com.activity-mesh.${unit} 2>/dev/null || true"
            run "rm -f \"$plist\""
            ok "removed $plist"
        fi
    done
}

uninstall_linux() {
    local unit svc
    for unit in watcher daemon; do
        svc="$HOME/.config/systemd/user/activity-mesh-${unit}.service"
        if [[ -f "$svc" || $DRY_RUN -eq 1 ]]; then
            run "systemctl --user disable --now activity-mesh-${unit}.service 2>/dev/null || true"
            run "rm -f \"$svc\""
            ok "removed $svc"
        fi
    done
    run "systemctl --user daemon-reload 2>/dev/null || true"
}

[[ "$OS" == "darwin" ]] && uninstall_macos
[[ "$OS" == "linux"  ]] && uninstall_linux

remove_bin() {
    local p="$1"
    [[ -f "$p" ]] || return 0
    if [[ -w "$(dirname "$p")" ]]; then run "rm -f \"$p\""
    else run "sudo rm -f \"$p\""; fi
    ok "removed $p"
}
remove_bin "$PREFIX/activity-log"
remove_bin "$PREFIX/activity-watcher"
remove_bin "$PREFIX/activity-mesh-daemon"

if [[ -d "$STORE_DIR/dist" || $DRY_RUN -eq 1 ]]; then
    run "rm -rf \"$STORE_DIR/dist\""
    ok "removed runtime assets $STORE_DIR/dist"
fi

if [[ $PURGE -eq 1 ]]; then
    for d in "$STORE_DIR" "$STATE_DIR" "$CONFIG_DIR"; do
        [[ -d "$d" ]] && { run "rm -rf \"$d\""; ok "purged $d"; }
    done
    warn "left $SYNC_DIR alone — it's the cross-host source-of-truth, delete by hand if intended"
elif [[ $KEEP_DATA -eq 1 ]]; then
    ok "preserved data: $STORE_DIR $STATE_DIR $SYNC_DIR $CONFIG_DIR"
fi

ok "uninstall complete"
[[ $DRY_RUN -eq 1 ]] && warn "dry-run only — re-run without --dry-run to apply"
exit 0
