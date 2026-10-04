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
run_argv() { if [[ $DRY_RUN -eq 1 ]]; then printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; else "$@"; fi; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFGEDIT="$HERE/lib/cfgedit.sh"
[[ -f "$CFGEDIT" ]] || { err "missing helper $CFGEDIT"; exit 1; }
# shellcheck source=lib/cfgedit.sh
. "$CFGEDIT"

UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *)      err "unsupported OS: $UNAME_S"; exit 1 ;;
esac

STORE_DIR="${ACTIVITY_MESH_HOME:-$HOME/.local/share/activity-mesh}"
STATE_DIR="${ACTIVITY_MESH_STATE:-$HOME/.local/state/activity-mesh}"
SYNC_DIR="${ACTIVITY_MESH_SYNC:-$HOME/Sync/activity}"
CONFIG_DIR="$HOME/.config/activity-mesh"

norm_lex() {
    local p="$1"
    while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s\n' "$p"
}

canon_path() {
    local p="$1" c
    if c="$(cd -P -- "$p" 2>/dev/null && pwd -P)"; then
        printf '%s\n' "$c"
        return 0
    fi
    if [[ "$p" == "/" ]]; then
        printf '/\n'
        return 0
    fi
    c="$(canon_path "$(dirname -- "$p")")"
    printf '%s/%s\n' "${c%/}" "$(basename -- "$p")"
}

covers() { [[ "$1" == "/" || "$2" == "$1" || "$2" == "$1"/* ]]; }

CANON_HOME="$(canon_path "$(norm_lex "$HOME")")"
CANON_SYNC="$(canon_path "$(norm_lex "$SYNC_DIR")")"

guard_dir() {
    local name="$1" raw="$2" managed
    case "$raw" in
        /*) ;;
        *) err "refusing to uninstall: $name=$raw is not an absolute path"; exit 1 ;;
    esac
    GUARD_LEX="$(norm_lex "$raw")"
    GUARD_CANON="$(canon_path "$GUARD_LEX")"
    if covers "$GUARD_CANON" "$CANON_HOME"; then
        err "refusing to uninstall: $name=$raw is your home directory or one of its parents"
        exit 1
    fi
    if covers "$GUARD_CANON" "$CANON_SYNC"; then
        err "refusing to uninstall: $name=$raw is the sync dir $CANON_SYNC or one of its parents"
        exit 1
    fi
    for managed in "$HOME/.local/share/activity-mesh" "$HOME/.local/state/activity-mesh" "$CONFIG_DIR"; do
        managed="$(canon_path "$(norm_lex "$managed")")"
        if [[ "$GUARD_CANON" != "$managed" ]] && covers "$GUARD_CANON" "$managed"; then
            err "refusing to uninstall: $name=$raw would take $managed with it"
            exit 1
        fi
    done
}
guard_dir ACTIVITY_MESH_HOME "$STORE_DIR"
STORE_LEX="$GUARD_LEX"
STORE_CANON="$GUARD_CANON"
guard_dir ACTIVITY_MESH_STATE "$STATE_DIR"
STATE_CANON="$GUARD_CANON"

uninstall_macos() {
    local unit plist
    for unit in watcher daemon health heartbeat compact weekly-digest; do
        plist="$HOME/Library/LaunchAgents/com.activity-mesh.${unit}.plist"
        if [[ -f "$plist" || $DRY_RUN -eq 1 ]]; then
            run "launchctl bootout gui/$(id -u)/com.activity-mesh.${unit} 2>/dev/null || true"
            run_argv rm -f "$plist"
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
            run_argv rm -f "$svc"
            ok "removed $svc"
        fi
    done
    run "systemctl --user daemon-reload 2>/dev/null || true"
}

[[ "$OS" == "darwin" ]] && uninstall_macos
[[ "$OS" == "linux"  ]] && uninstall_linux

DIST_A="$STORE_LEX/dist"
DIST_B="$STORE_CANON/dist"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="$HOME/.claude.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
HERMES_CONFIG="$HOME/.hermes/config.yaml"

JQ_STRIP_HOOKS='
def ours: ((.command? // "") | (type == "string") and (startswith($d1) or startswith($d2)));
def prune: if type == "array" then
    [ .[] | . as $g
      | if ((($g.hooks? // []) | type) == "array") and (($g.hooks // []) | map(ours) | any)
        then ($g | .hooks |= map(select(ours | not))) | select((.hooks | length) > 0)
        else $g end ]
  else . end;
. as $orig
| if ((.hooks? // null) | type) == "object" then
    .hooks |= with_entries(
        (.value | prune) as $p
        | if ((.value | type) == "array") and (($p | length) == 0) and ((.value | length) > 0) then empty else .value = $p end)
  else . end
| if ((.hooks? // null) | type) == "object" and (.hooks | length) == 0 and (($orig.hooks // {}) | length) > 0
  then del(.hooks) else . end'

dry() { printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; }

edit_config() {
    local f="$1" new="$2" bak
    bak="$f.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$f" "$bak" || { err "cannot back up $f — left untouched"; return 1; }
    write_through "$f" < "$new" || { err "cannot write $f — left untouched (backup at $bak)"; return 1; }
    ok "updated $f (backup at $bak)"
}

unhook_claude() {
    local f="$CLAUDE_SETTINGS" tmp
    [[ -f "$f" ]] || return 0
    grep -qF -e "$DIST_A/" -e "$DIST_B/" "$f" || return 0
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — remove the hook commands under $DIST_B/ from $f by hand"
        return 0
    fi
    tmp="$(mktemp)"
    if ! jq --arg d1 "$DIST_A/" --arg d2 "$DIST_B/" "$JQ_STRIP_HOOKS" "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "cannot parse $f — remove the hook commands under $DIST_B/ by hand"
        return 0
    fi
    if [[ "$(jq -S . "$f")" == "$(jq -S . "$tmp")" ]]; then
        rm -f "$tmp"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "remove the hook commands under $DIST_B/ from $f"
    else
        edit_config "$f" "$tmp" || true
    fi
    rm -f "$tmp"
}

unregister_claude_mcp() {
    local f="$CLAUDE_JSON" tmp
    [[ -f "$f" ]] || return 0
    grep -qF -e "$DIST_A/" -e "$DIST_B/" "$f" || return 0
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — if $f registers activity-mesh from $DIST_B/, run: claude mcp remove activity-mesh --scope user"
        return 0
    fi
    jq -e --arg d1 "$DIST_A/" --arg d2 "$DIST_B/" '[.mcpServers["activity-mesh"]? | ((.command? // empty), ((.args? // [])[]?)) | strings | select(startswith($d1) or startswith($d2))] | length > 0' "$f" >/dev/null 2>&1 || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "remove the activity-mesh MCP server registered from $DIST_B/ ($f)"
        return 0
    fi
    if command -v claude >/dev/null 2>&1; then
        if claude mcp remove activity-mesh --scope user >/dev/null 2>&1; then
            ok "removed the activity-mesh MCP server (claude mcp remove)"
        else
            warn "claude mcp remove activity-mesh --scope user failed — remove it by hand"
        fi
        return 0
    fi
    tmp="$(mktemp)"
    if jq 'del(.mcpServers["activity-mesh"])' "$f" > "$tmp"; then
        edit_config "$f" "$tmp" || true
    else
        warn "cannot rewrite $f — run: claude mcp remove activity-mesh --scope user"
    fi
    rm -f "$tmp"
}

unregister_codex_mcp() {
    local f="$CODEX_CONFIG" tmp check leftover
    [[ -f "$f" ]] || return 0
    grep -qF -e "$DIST_A/" -e "$DIST_B/" "$f" || return 0
    tmp="$(mktemp)"
    check="$f"
    if toml_edit_server strip "$f" "$tmp" "$DIST_A/" "$DIST_B/"; then
        check="$tmp"
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "remove [mcp_servers.activity-mesh] (registered from $DIST_B/) from $f"
        else
            edit_config "$f" "$tmp" || true
        fi
    fi
    leftover="$(grep -v '^[[:space:]]*#' "$check" | grep -F -e "$DIST_A/" -e "$DIST_B/" || true)"
    if [[ -n "$leftover" ]]; then
        warn "$f still points into $DIST_B/ (an inline table or another entry) — edit it by hand"
    fi
    rm -f "$tmp"
}

warn_hermes_mcp() {
    [[ -f "$HERMES_CONFIG" ]] || return 0
    grep -qF -e "$DIST_A/" -e "$DIST_B/" "$HERMES_CONFIG" || return 0
    warn "$HERMES_CONFIG points into $DIST_B/ — remove its activity-mesh entry under mcp_servers by hand"
}

unhook_claude
unregister_claude_mcp
unregister_codex_mcp
warn_hermes_mcp

remove_bin() {
    local p="$1"
    [[ -f "$p" ]] || return 0
    if [[ -w "$(dirname "$p")" ]]; then run_argv rm -f "$p"
    else run_argv sudo rm -f "$p"; fi
    ok "removed $p"
}
for bin_name in activity-log activity-watcher activity-mesh-daemon; do
    remove_bin "$PREFIX/$bin_name"
    if [[ "$PREFIX" != "$HOME/.local/bin" ]]; then remove_bin "$HOME/.local/bin/$bin_name"; fi
done

if [[ -d "$DIST_B" || $DRY_RUN -eq 1 ]]; then
    run_argv rm -rf "$DIST_B"
    ok "removed runtime assets $DIST_B"
fi

if [[ $PURGE -eq 1 ]]; then
    for d in "$STORE_CANON" "$STATE_CANON" "$CONFIG_DIR"; do
        [[ -d "$d" ]] && { run_argv rm -rf "$d"; ok "purged $d"; }
    done
    warn "left $SYNC_DIR alone — it's the cross-host source-of-truth, delete by hand if intended"
elif [[ $KEEP_DATA -eq 1 ]]; then
    ok "preserved data: $STORE_CANON $STATE_CANON $SYNC_DIR $CONFIG_DIR"
fi

ok "uninstall complete"
[[ $DRY_RUN -eq 1 ]] && warn "dry-run only — re-run without --dry-run to apply"
exit 0
