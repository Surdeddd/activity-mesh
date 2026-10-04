# shellcheck shell=bash

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

STAT_ID_FMT=bsd
if stat -L -c '%d:%i' / > /dev/null 2>&1; then STAT_ID_FMT=gnu; fi

phys_pwd() {
    if [[ -x /bin/pwd ]]; then /bin/pwd -P
    elif [[ -x /usr/bin/pwd ]]; then /usr/bin/pwd -P
    else pwd -P; fi
}

norm_lex() {
    local p="$1"
    while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s\n' "$p"
}

canon_path() {
    local p="$1" rest="" c head
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    while :; do
        if c="$(cd -P -- "$p" 2>/dev/null && phys_pwd)"; then
            if [[ -z "$rest" ]]; then printf '%s\n' "$c"; else printf '%s/%s\n' "${c%/}" "$rest"; fi
            return 0
        fi
        if [[ "$p" == "/" || "$p" == "." ]]; then
            printf '%s/%s\n' "${p%/}" "$rest"
            return 0
        fi
        if [[ "$p" == */* ]]; then
            head="${p%/*}"
            [[ -n "$head" ]] || head="/"
        else
            head="."
        fi
        if [[ -z "$rest" ]]; then rest="${p##*/}"; else rest="${p##*/}/$rest"; fi
        p="$head"
    done
}

covers() { [[ "$1" == "/" || "$2" == "$1" || "$2" == "$1"/* ]]; }

dir_id() {
    local i
    if [[ "$STAT_ID_FMT" == gnu ]]; then
        i="$(stat -L -c '%d:%i' "$1" 2>/dev/null)" || return 1
    else
        i="$(stat -L -f '%d:%i' "$1" 2>/dev/null)" || return 1
    fi
    case "$i" in ""|*[!0-9:]*) return 1 ;; esac
    printf '%s\n' "$i"
}

chain_ids() {
    local p="$1" chain=()
    while :; do
        chain[${#chain[@]}]="$p"
        [[ "$p" == */* && "$p" != "/" ]] || break
        p="${p%/*}"
        [[ -n "$p" ]] || p="/"
    done
    if [[ "$STAT_ID_FMT" == gnu ]]; then
        stat -L -c '%d:%i' -- "${chain[@]}" 2>/dev/null || true
    else
        stat -L -f '%d:%i' -- "${chain[@]}" 2>/dev/null || true
    fi
}

json_unescape() {
    local s="$1" out=""
    while [[ "$s" == *\\* ]]; do
        out="$out${s%%\\*}"
        s="${s#*\\}"
        case "$s" in
            \"*) out="$out\""; s="${s:1}" ;;
            \\*) out="$out\\"; s="${s:1}" ;;
            u0026*) out="$out&"; s="${s:5}" ;;
            u003[cC]*) out="$out<"; s="${s:5}" ;;
            u003[eE]*) out="$out>"; s="${s:5}" ;;
            *) return 1 ;;
        esac
    done
    printf '%s' "$out$s"
}

config_sync_dir() {
    local cfg="$1" prev
    [[ -f "$cfg" ]] || return 0
    prev="$(sed -n -E 's/.*"sync_dir"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$cfg" | head -1 || true)"
    [[ -n "$prev" ]] || return 0
    json_unescape "$prev"
}

toml_classify() {
    local h="$1" pq cq
    TOML_KIND=other
    for pq in mcp_servers '"mcp_servers"' "'mcp_servers'"; do
        for cq in activity-mesh '"activity-mesh"' "'activity-mesh'"; do
            case "$h" in
                "[$pq.$cq]") TOML_KIND=main; return 0 ;;
                "[$pq.$cq."*|"[[$pq.$cq."*) TOML_KIND=sub; return 0 ;;
            esac
        done
    done
}

toml_edit_server() {
    local mode="$1" cfg="$2" out="$3" arg1="${4:-}" arg2="${5:-}"
    local lines=() n=0 i pass pass_from=2 line norm code chunk body pend hit dropped first header eof dest
    local any_hit=0 replaced=0 changed=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines[n]="$line"
        n=$((n + 1))
    done < "$cfg"
    if [[ "$mode" == strip ]]; then pass_from=1; fi
    for ((pass = pass_from; pass <= 2; pass++)); do
        chunk=""
        body=""
        pend=""
        hit=0
        dest="$out"
        if [[ $pass -eq 1 ]]; then dest=/dev/null; else : > "$out"; fi
        for ((i = 0; i <= n; i++)); do
            header=0
            eof=0
            if [[ $i -eq $n ]]; then
                eof=1
                line=""
                norm=""
            else
                line="${lines[i]}"
                norm="${line//[[:space:]]/}"
                norm="${norm%%#*}"
                if [[ "$norm" == '['* ]]; then header=1; fi
            fi
            if [[ $header -eq 1 || $eof -eq 1 ]]; then
                if [[ -n "$chunk" ]]; then
                    dropped=0
                    if [[ $pass -eq 1 ]]; then
                        if [[ "$chunk" == main && $hit -eq 1 ]]; then any_hit=1; fi
                    else
                        case "$mode:$chunk" in
                            replace:main)
                                if [[ $replaced -eq 0 ]]; then printf '%s\n' "$arg1" >> "$dest"; replaced=1; fi
                                changed=1 ;;
                            replace:sub)
                                printf '%s' "$body" >> "$dest" ;;
                            strip:main|strip:sub)
                                if [[ $any_hit -eq 1 ]]; then dropped=1; changed=1; else printf '%s' "$body" >> "$dest"; fi ;;
                        esac
                    fi
                    if [[ $dropped -eq 1 ]]; then
                        while [[ -n "$pend" ]]; do
                            first="${pend%%$'\n'*}"
                            [[ -z "${first//[[:space:]]/}" ]] || break
                            pend="${pend#*$'\n'}"
                        done
                    fi
                    printf '%s' "$pend" >> "$dest"
                    chunk=""
                    body=""
                    pend=""
                    hit=0
                fi
                if [[ $header -eq 1 ]]; then
                    toml_classify "$norm"
                    if [[ "$TOML_KIND" == other ]]; then
                        printf '%s\n' "$line" >> "$dest"
                    else
                        chunk="$TOML_KIND"
                        body="$line"$'\n'
                    fi
                fi
            elif [[ -n "$chunk" ]]; then
                if [[ -z "$norm" ]]; then
                    pend="$pend$line"$'\n'
                else
                    body="$body$pend$line"$'\n'
                    pend=""
                    if [[ "$mode" == strip ]]; then
                        code="${line%%#*}"
                        if [[ -n "$arg1" && "$code" == *"$arg1"* ]]; then hit=1; fi
                        if [[ -n "$arg2" && "$code" == *"$arg2"* ]]; then hit=1; fi
                    fi
                fi
            else
                printf '%s\n' "$line" >> "$dest"
            fi
        done
    done
    [[ $changed -eq 1 ]]
}

TOML_PARENT_RE='(mcp_servers|"mcp_servers"|'"'mcp_servers'"')'
TOML_CHILD_RE='(activity-mesh|"activity-mesh"|'"'activity-mesh'"')'

toml_defines_elsewhere() {
    local cfg="$1" line norm n=0 where=top re_key re_dotted re_inline
    re_key="^[[:space:]]*${TOML_CHILD_RE}[[:space:]]*[.=]"
    re_dotted="^[[:space:]]*${TOML_PARENT_RE}[[:space:]]*\\.[[:space:]]*${TOML_CHILD_RE}[[:space:]]*[.=]"
    re_inline="^[[:space:]]*${TOML_PARENT_RE}[[:space:]]*=[[:space:]]*\\{(.*[{,])?[[:space:]]*${TOML_CHILD_RE}[[:space:]]*[.=]"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        norm="${line//[[:space:]]/}"
        norm="${norm%%#*}"
        [[ -n "$norm" ]] || continue
        if [[ "$norm" == '['* ]]; then
            case "$norm" in
                '[mcp_servers]'|'["mcp_servers"]'|"['mcp_servers']") where=servers ;;
                *) where=other ;;
            esac
            continue
        fi
        case "$where" in
            servers)
                if [[ "$line" =~ $re_key ]]; then printf '%s\n' "$n"; return 0; fi ;;
            top)
                if [[ "$line" =~ $re_dotted ]] || [[ "$line" =~ $re_inline ]]; then printf '%s\n' "$n"; return 0; fi ;;
        esac
    done < "$cfg"
    return 1
}
