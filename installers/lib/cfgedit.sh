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
