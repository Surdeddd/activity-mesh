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
refuse() { err "refusing to uninstall: $*"; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; else eval "$*"; fi; }
run_argv() { if [[ $DRY_RUN -eq 1 ]]; then printf '%bDRY%b %s\n' "$Y" "$N" "$*" >&2; else "$@"; fi; }

SELF="${BASH_SOURCE[0]}"
hops=0
while [[ -L "$SELF" && $hops -lt 20 ]]; do
    link="$(readlink "$SELF")"
    case "$link" in /*) SELF="$link" ;; *) SELF="$(cd -P "$(dirname "$SELF")" && pwd)/$link" ;; esac
    hops=$((hops + 1))
done
HERE="$(cd "$(dirname "$SELF")" && pwd)"
HERE_P="$(cd -P "$(dirname "$SELF")" && pwd)"
if [[ "$(cd -P "$HERE" && pwd)" != "$HERE_P" ]]; then HERE="$HERE_P"; fi
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

if [[ "$OS" == darwin && ! -x /bin/pwd && ! -x /usr/bin/pwd ]]; then
    refuse "neither /bin/pwd nor /usr/bin/pwd exists, so a path cannot be resolved to the name the filesystem stores"
fi

DEFAULT_STORE="$HOME/.local/share/activity-mesh"
DEFAULT_STATE="$HOME/.local/state/activity-mesh"
CONFIG_DIR="$HOME/.config/activity-mesh"
STORE_DIR="${ACTIVITY_MESH_HOME:-$DEFAULT_STORE}"
STATE_DIR="${ACTIVITY_MESH_STATE:-$DEFAULT_STATE}"

check_value() {
    case "$2" in
        *$'\n'*) refuse "$1 contains a newline" ;;
        /*) ;;
        *) refuse "$1=$2 is not an absolute path" ;;
    esac
}

resolve_dir() {
    local a b
    check_value "$1" "$2"
    RES_LEX="$(norm_lex "$2")"
    RES_CANON="$(canon_path "$RES_LEX")"
    case "$RES_CANON/" in
        */./*|*/../*) refuse "$1=$2 uses . or .. below something that does not exist, so it cannot be resolved" ;;
    esac
    if [[ -e "$RES_LEX" ]]; then
        a="$(dir_id "$RES_LEX" 2>/dev/null || true)"
        b="$(dir_id "$RES_CANON" 2>/dev/null || true)"
        [[ -n "$a" && -n "$b" ]] || refuse "$1=$2: cannot read the identity of that directory (is stat available?)"
        [[ "$a" == "$b" ]] || refuse "$1=$2 does not resolve to the directory it names (a newline or another unusual character in a path component?)"
    fi
}

parent_of() {
    local p="${1%/*}"
    printf '%s\n' "${p:-/}"
}

in_ids() {
    [[ -n "$1" ]] || return 1
    case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}

covers_any() { covers "$1" "$3" || covers "$1" "$4" || covers "$2" "$3" || covers "$2" "$4"; }

P_LEX=()
P_CANON=()
P_IDS=()
P_WHY=()
add_protected() {
    local n="${#P_LEX[@]}"
    P_LEX[n]="$1"
    P_CANON[n]="$2"
    P_IDS[n]="$(chain_ids "$1")"
    if [[ "$1" != "$2" ]]; then P_IDS[n]="${P_IDS[n]}"$'\n'"$(chain_ids "$2")"; fi
    P_WHY[n]="$3"
}

protect() {
    add_protected "$1" "$2" "$3"
    if [[ "$OS" == darwin && "$2" != /System/Volumes/Data && "$2" != /System/Volumes/Data/* && -e "/System/Volumes/Data$2" ]]; then
        add_protected "/System/Volumes/Data$2" "/System/Volumes/Data$2" "$3"
    fi
}

guard_dir() {
    local name="$1" raw="$2" lex="$3" canon="$4" id i
    id="$(dir_id "$canon" 2>/dev/null || true)"
    for ((i = 0; i < ${#P_LEX[@]}; i++)); do
        if covers_any "$lex" "$canon" "${P_LEX[i]}" "${P_CANON[i]}" || in_ids "$id" "${P_IDS[i]}"; then
            refuse "$name=$raw ${P_WHY[i]}"
        fi
    done
    for ((i = 0; i < ${#S_LEX[@]}; i++)); do
        if covers_any "${S_LEX[i]}" "${S_CANON[i]}" "$lex" "$canon"; then
            refuse "$name=$raw is inside the sync dir ${S_LEX[i]}"
        fi
    done
}

S_LEX=()
S_CANON=()
SYNC_EFFECTIVE=""
add_sync() {
    local label="$1" raw effective="$3" tilde='~'
    raw="$(trim_ws "$2")"
    [[ -n "$raw" ]] || return 0
    case "$raw" in
        "$tilde") raw="$HOME" ;;
        "$tilde"/*) raw="$HOME/${raw:2}" ;;
    esac
    case "$raw" in /*) ;; *) raw="$PWD/$raw" ;; esac
    resolve_dir "$label" "$raw"
    S_LEX[${#S_LEX[@]}]="$RES_LEX"
    S_CANON[${#S_CANON[@]}]="$RES_CANON"
    protect "$RES_LEX" "$RES_CANON" "is the sync dir $RES_LEX or one of its parents"
    if [[ "$effective" == 1 && -z "$SYNC_EFFECTIVE" ]]; then SYNC_EFFECTIVE="$RES_LEX"; fi
}

sync_from_config() {
    local cfg="$1" effective="$2" v
    [[ -f "$cfg" ]] || return 0
    if ! v="$(config_sync_dir "$cfg")"; then
        if [[ -n "${ACTIVITY_MESH_SYNC:-}" ]]; then
            warn "cannot decode sync_dir in $cfg — ignored, ACTIVITY_MESH_SYNC names the sync dir"
            return 0
        fi
        refuse "cannot decode sync_dir in $cfg — set ACTIVITY_MESH_SYNC to the sync dir and re-run"
    fi
    [[ -z "$v" ]] || add_sync "sync_dir in $cfg" "$v" "$effective"
}

resolve_dir HOME "$HOME"
dir_id "$RES_CANON" > /dev/null 2>&1 || refuse "cannot read the identity of HOME=$HOME"
protect "$RES_LEX" "$RES_CANON" "is your home directory or one of its parents"

resolve_dir ACTIVITY_MESH_HOME "$STORE_DIR"
STORE_LEX="$RES_LEX"
STORE_CANON="$RES_CANON"
resolve_dir ACTIVITY_MESH_STATE "$STATE_DIR"
STATE_LEX="$RES_LEX"
STATE_CANON="$RES_CANON"
resolve_dir CONFIG_DIR "$CONFIG_DIR"
CONFIG_LEX="$RES_LEX"
CONFIG_CANON="$RES_CANON"

if [[ -n "${ACTIVITY_MESH_SYNC:-}" ]]; then add_sync ACTIVITY_MESH_SYNC "$ACTIVITY_MESH_SYNC" 1; fi
sync_from_config "$STORE_LEX/config.json" 1
if [[ "$STORE_CANON" != "$(canon_path "$(norm_lex "$DEFAULT_STORE")")" ]]; then
    sync_from_config "$DEFAULT_STORE/config.json" 0
fi
add_sync "the default sync dir" "$HOME/Sync/activity" 1

for managed in "$DEFAULT_STORE" "$DEFAULT_STATE" "$CONFIG_DIR"; do
    resolve_dir "the default dir $managed" "$managed"
    protect "$(parent_of "$RES_LEX")" "$(parent_of "$RES_CANON")" "would take $RES_CANON with it"
done

guard_dir ACTIVITY_MESH_HOME "$STORE_DIR" "$STORE_LEX" "$STORE_CANON"
guard_dir ACTIVITY_MESH_STATE "$STATE_DIR" "$STATE_LEX" "$STATE_CANON"
guard_dir CONFIG_DIR "$CONFIG_DIR" "$CONFIG_LEX" "$CONFIG_CANON"

VERSION_DIR_RE='^(v?[0-9][0-9A-Za-z._+-]*|dev-local)$'
SHAPE_BAD=()
SHAPE_SEEN=()
SHAPE_MARKERS=0

volume_root() {
    local c="$1" id pid
    [[ "$c" != "/" ]] || return 0
    if [[ "$OS" == darwin ]]; then
        case "$c" in
            /System|/System/Volumes) return 0 ;;
            /System/Volumes/*) [[ "${c#/System/Volumes/}" == */* ]] || return 0 ;;
        esac
    fi
    id="$(dir_id "$c" 2>/dev/null)" || refuse "cannot read the identity of $c"
    pid="$(dir_id "$(parent_of "$c")" 2>/dev/null)" || refuse "cannot read the identity of $(parent_of "$c")"
    [[ "${id%%:*}" != "${pid%%:*}" ]]
}

sub_expected() {
    case "$1:$2" in
        store:audit|store:dist) return 0 ;;
        dist:*) [[ "$2" =~ $VERSION_DIR_RE ]] ;;
        *) return 1 ;;
    esac
}

shape_scan() {
    local kind="$1" dir="$2" e name dev
    SHAPE_BAD=()
    SHAPE_SEEN=()
    SHAPE_MARKERS=0
    dev="$(dir_id "$dir" 2>/dev/null)" || refuse "cannot read the identity of $dir"
    dev="${dev%%:*}"
    for e in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$e" || -L "$e" ]] || continue
        name="${e##*/}"
        SHAPE_SEEN[${#SHAPE_SEEN[@]}]="$name"
        if [[ -d "$e" && ! -L "$e" ]]; then
            if sub_expected "$kind" "$name" && [[ "$(dir_id "$e" 2>/dev/null)" == "$dev":* ]]; then continue; fi
            SHAPE_BAD[${#SHAPE_BAD[@]}]="$name/"
            continue
        fi
        case "$kind:$name" in
            dist:current)
                if [[ ! -L "$e" ]]; then SHAPE_BAD[${#SHAPE_BAD[@]}]="$name"; fi ;;
            dist:.DS_Store) ;;
            dist:*)
                SHAPE_BAD[${#SHAPE_BAD[@]}]="$name" ;;
            store:config.json|store:cursors.json|store:index.db|store:seq-*)
                if [[ -f "$e" ]]; then SHAPE_MARKERS=$((SHAPE_MARKERS + 1)); fi ;;
            state:*.log|state:*.err|state:last-health.json|state:last-digest.json|state:heartbeat-misses|state:heartbeat-last-alert|state:clock-offset-ms|state:decay-state.json|state:tokens-*)
                if [[ -f "$e" ]]; then SHAPE_MARKERS=$((SHAPE_MARKERS + 1)); fi ;;
            config:watcher.yaml|config:scopes-cache|config:agents-cache|config:telegram.env)
                if [[ -f "$e" ]]; then SHAPE_MARKERS=$((SHAPE_MARKERS + 1)); fi ;;
        esac
    done
    if [[ "$kind" == store && -L "$dir/dist/current" ]]; then SHAPE_MARKERS=$((SHAPE_MARKERS + 1)); fi
}

identify_dir() {
    local name="$1" raw="$2" kind="$3" dir="$4" what shown="" n
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    case "$kind" in
        store) what="an activity-mesh store dir" ;;
        state) what="an activity-mesh state dir" ;;
        config) what="an activity-mesh config dir" ;;
        dist) what="activity-mesh's runtime assets dir" ;;
    esac
    if volume_root "$dir"; then refuse "$name=$raw: $dir is a mount point or a volume root, not $what"; fi
    [[ -r "$dir" && -x "$dir" ]] || refuse "$name=$raw: cannot list $dir"
    shape_scan "$kind" "$dir"
    if [[ ${#SHAPE_BAD[@]} -gt 0 ]]; then
        for ((n = 0; n < ${#SHAPE_BAD[@]} && n < 5; n++)); do shown="$shown${shown:+, }${SHAPE_BAD[n]}"; done
        if [[ ${#SHAPE_BAD[@]} -gt 5 ]]; then shown="$shown (and $((${#SHAPE_BAD[@]} - 5)) more)"; fi
        refuse "$name=$raw: $dir is not $what, it holds unexpected entries: $shown"
    fi
    if [[ "$kind" != dist && $SHAPE_MARKERS -eq 0 ]]; then
        for ((n = 0; n < ${#SHAPE_SEEN[@]} && n < 5; n++)); do shown="$shown${shown:+, }${SHAPE_SEEN[n]}"; done
        if [[ -z "$shown" ]]; then shown="it is empty, and an empty dir has to be removed by hand"; else shown="it holds only: $shown"; fi
        refuse "$name=$raw: $dir is not $what, it holds none of the files such a dir has ($shown)"
    fi
}

identify_dir ACTIVITY_MESH_HOME "$STORE_DIR" dist "$STORE_CANON/dist"
if [[ $PURGE -eq 1 ]]; then
    identify_dir ACTIVITY_MESH_HOME "$STORE_DIR" store "$STORE_CANON"
    identify_dir ACTIVITY_MESH_STATE "$STATE_DIR" state "$STATE_CANON"
    identify_dir CONFIG_DIR "$CONFIG_DIR" config "$CONFIG_CANON"
fi

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

purge_dir() {
    local p="$2" hops=0 target base
    if [[ -d "$1" ]]; then
        run_argv rm -rf "$1"
        ok "purged $1"
    fi
    while [[ -L "$p" && $hops -lt 20 ]]; do
        target="$(readlink "$p")"
        base="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || break
        run_argv rm -f "$p"
        ok "removed the link $p"
        case "$target" in /*) p="$target" ;; *) p="$base/$target" ;; esac
        hops=$((hops + 1))
    done
}

if [[ $PURGE -eq 1 ]]; then
    purge_dir "$STORE_CANON" "$STORE_LEX"
    purge_dir "$STATE_CANON" "$STATE_LEX"
    purge_dir "$CONFIG_CANON" "$CONFIG_LEX"
    warn "left $SYNC_EFFECTIVE alone — it's the cross-host source-of-truth, delete by hand if intended"
elif [[ $KEEP_DATA -eq 1 ]]; then
    ok "preserved data: $STORE_CANON $STATE_CANON $SYNC_EFFECTIVE $CONFIG_CANON"
fi

ok "uninstall complete"
[[ $DRY_RUN -eq 1 ]] && warn "dry-run only — re-run without --dry-run to apply"
exit 0
