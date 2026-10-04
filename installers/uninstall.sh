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

guard_dir() {
    case "$2" in
        .|..|/|"$HOME"|"$HOME"/) err "refusing to uninstall: $1=$2 is not a dedicated directory"; exit 1 ;;
    esac
}
guard_dir ACTIVITY_MESH_HOME "$STORE_DIR"
guard_dir ACTIVITY_MESH_STATE "$STATE_DIR"

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

DIST_DIR="$STORE_DIR/dist"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="$HOME/.claude.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
HERMES_CONFIG="$HOME/.hermes/config.yaml"

JQ_STRIP_HOOKS='
def ours: ((.command? // "") | (type == "string") and startswith($d));
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

write_through() {
    local real="$1" n=0 t mode tmp
    while [[ -L "$real" && $n -lt 20 ]]; do
        t="$(readlink "$real")"
        case "$t" in /*) real="$t" ;; *) real="$(dirname "$real")/$t" ;; esac
        n=$((n + 1))
    done
    mode="$(stat -c %a "$real" 2>/dev/null || stat -f %Lp "$real" 2>/dev/null)" || mode=""
    tmp="$(mktemp "$real.XXXXXX")" || return 1
    if cat > "$tmp" && { [[ -z "$mode" ]] || chmod "$mode" "$tmp"; } && mv -f "$tmp" "$real"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

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
    grep -qF -- "$DIST_DIR/" "$f" || return 0
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — remove the hook commands under $DIST_DIR/ from $f by hand"
        return 0
    fi
    tmp="$(mktemp)"
    if ! jq --arg d "$DIST_DIR/" "$JQ_STRIP_HOOKS" "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "cannot parse $f — remove the hook commands under $DIST_DIR/ by hand"
        return 0
    fi
    if [[ "$(jq -S . "$f")" == "$(jq -S . "$tmp")" ]]; then
        rm -f "$tmp"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "remove the hook commands under $DIST_DIR/ from $f"
    else
        edit_config "$f" "$tmp" || true
    fi
    rm -f "$tmp"
}

unregister_claude_mcp() {
    local f="$CLAUDE_JSON" tmp
    [[ -f "$f" ]] || return 0
    grep -qF -- "$DIST_DIR/" "$f" || return 0
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — if $f registers activity-mesh from $DIST_DIR/, run: claude mcp remove activity-mesh --scope user"
        return 0
    fi
    jq -e --arg d "$DIST_DIR/" '[.mcpServers["activity-mesh"]? | ((.command? // empty), ((.args? // [])[]?)) | strings | select(startswith($d))] | length > 0' "$f" >/dev/null 2>&1 || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "remove the activity-mesh MCP server registered from $DIST_DIR/ ($f)"
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

is_ours_header() {
    case "$1" in
        '[mcp_servers.activity-mesh]'|'[mcp_servers."activity-mesh"]'|"[mcp_servers.'activity-mesh']") return 0 ;;
        '[mcp_servers.activity-mesh.'*|'[mcp_servers."activity-mesh".'*|"[mcp_servers.'activity-mesh'."*) return 0 ;;
    esac
    return 1
}

codex_strip() {
    local cfg="$1" out="$2" line norm inblock=0 hit=0 removed=0 buf="" pend=""
    : > "$out"
    while IFS= read -r line || [[ -n "$line" ]]; do
        norm="${line//[[:space:]]/}"
        norm="${norm%%#*}"
        case "$norm" in
            '['*)
                if is_ours_header "$norm"; then
                    inblock=1
                    buf="$buf$pend"
                    pend=""
                elif [[ $inblock -eq 1 ]]; then
                    if [[ $hit -eq 1 ]]; then removed=1; else printf '%s' "$buf" >> "$out"; fi
                    printf '%s' "$pend" >> "$out"
                    inblock=0; hit=0; buf=""; pend=""
                fi ;;
        esac
        if [[ $inblock -eq 1 ]]; then
            if [[ -z "$norm" ]]; then
                pend="$pend$line"$'\n'
            else
                buf="$buf$pend$line"$'\n'
                pend=""
                case "$line" in *"$DIST_DIR/"*) hit=1 ;; esac
            fi
        else
            printf '%s\n' "$line" >> "$out"
        fi
    done < "$cfg"
    if [[ $inblock -eq 1 ]]; then
        if [[ $hit -eq 1 ]]; then removed=1; else printf '%s' "$buf" >> "$out"; fi
        printf '%s' "$pend" >> "$out"
    fi
    [[ $removed -eq 1 ]]
}

unregister_codex_mcp() {
    local f="$CODEX_CONFIG" tmp
    [[ -f "$f" ]] || return 0
    grep -qF -- "$DIST_DIR/" "$f" || return 0
    tmp="$(mktemp)"
    if ! codex_strip "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "remove [mcp_servers.activity-mesh] (registered from $DIST_DIR/) from $f"
    else
        edit_config "$f" "$tmp" || true
    fi
    rm -f "$tmp"
}

warn_hermes_mcp() {
    [[ -f "$HERMES_CONFIG" ]] || return 0
    grep -qF -- "$DIST_DIR/" "$HERMES_CONFIG" || return 0
    warn "$HERMES_CONFIG points into $DIST_DIR/ — remove its activity-mesh entry under mcp_servers by hand"
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

if [[ -d "$STORE_DIR/dist" || $DRY_RUN -eq 1 ]]; then
    run_argv rm -rf "$STORE_DIR/dist"
    ok "removed runtime assets $STORE_DIR/dist"
fi

if [[ $PURGE -eq 1 ]]; then
    for d in "$STORE_DIR" "$STATE_DIR" "$CONFIG_DIR"; do
        [[ -d "$d" ]] && { run_argv rm -rf "$d"; ok "purged $d"; }
    done
    warn "left $SYNC_DIR alone — it's the cross-host source-of-truth, delete by hand if intended"
elif [[ $KEEP_DATA -eq 1 ]]; then
    ok "preserved data: $STORE_DIR $STATE_DIR $SYNC_DIR $CONFIG_DIR"
fi

ok "uninstall complete"
[[ $DRY_RUN -eq 1 ]] && warn "dry-run only — re-run without --dry-run to apply"
exit 0
