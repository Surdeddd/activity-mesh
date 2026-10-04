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

toml_classify() {
    case "$1" in
        '[mcp_servers.activity-mesh]'|'[mcp_servers."activity-mesh"]'|"[mcp_servers.'activity-mesh']") TOML_KIND=main ;;
        '[mcp_servers.activity-mesh.'*|'[mcp_servers."activity-mesh".'*|"[mcp_servers.'activity-mesh'."*) TOML_KIND=sub ;;
        *) TOML_KIND=other ;;
    esac
}

toml_edit_server() {
    local mode="$1" cfg="$2" out="$3" arg1="${4:-}" arg2="${5:-}"
    local lines=() n=0 i line norm code chunk="" body="" pend="" hit=0 drop=0 replaced=0 changed=0 dropped first header eof
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines[n]="$line"
        n=$((n + 1))
    done < "$cfg"
    : > "$out"
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
                case "$mode:$chunk" in
                    replace:main)
                        if [[ $replaced -eq 0 ]]; then printf '%s\n' "$arg1" >> "$out"; replaced=1; fi
                        changed=1 ;;
                    replace:sub)
                        printf '%s' "$body" >> "$out" ;;
                    strip:main)
                        if [[ $hit -eq 1 ]]; then dropped=1; drop=1; changed=1; else drop=0; printf '%s' "$body" >> "$out"; fi ;;
                    strip:sub)
                        if [[ $hit -eq 1 || $drop -eq 1 ]]; then dropped=1; drop=1; changed=1; else printf '%s' "$body" >> "$out"; fi ;;
                esac
                if [[ $dropped -eq 1 ]]; then
                    while [[ -n "$pend" ]]; do
                        first="${pend%%$'\n'*}"
                        [[ -z "${first//[[:space:]]/}" ]] || break
                        pend="${pend#*$'\n'}"
                    done
                fi
                printf '%s' "$pend" >> "$out"
                chunk=""
                body=""
                pend=""
                hit=0
            fi
            if [[ $header -eq 1 ]]; then
                toml_classify "$norm"
                if [[ "$TOML_KIND" == other ]]; then
                    drop=0
                    printf '%s\n' "$line" >> "$out"
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
            printf '%s\n' "$line" >> "$out"
        fi
    done
    [[ $changed -eq 1 ]]
}
