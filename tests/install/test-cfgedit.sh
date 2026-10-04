#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/amesh-cfgedit-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
toml_ok() {
    command -v python3 > /dev/null 2>&1 || return 0
    python3 -c 'import tomllib' 2> /dev/null || return 0
    python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1"
}

# shellcheck source=../../installers/lib/cfgedit.sh
. "$REPO_ROOT/installers/lib/cfgedit.sh"

BLOCK='[mcp_servers.activity-mesh]
command = "/usr/bin/node"
args = ["/srv/mcp/server.mjs"]'
NEEDLE_A="/h/.local/share/activity-mesh/dist/"
NEEDLE_B="/c/.local/share/activity-mesh/dist/"
IN="$WORK/in.toml"
WANT="$WORK/want.toml"
GOT="$WORK/got.toml"

expect() {
    local label="$1" mode="$2" want_rc="$3" rc
    set +e
    if [ "$mode" = replace ]; then
        toml_edit_server replace "$IN" "$GOT" "$BLOCK"
    else
        toml_edit_server strip "$IN" "$GOT" "$NEEDLE_A" "$NEEDLE_B"
    fi
    rc=$?
    set -e
    [ "$rc" -eq "$want_rc" ] || fail "$label: toml_edit_server $mode returned $rc, expected $want_rc"
    if ! cmp -s "$GOT" "$WANT"; then
        diff -u "$WANT" "$GOT" >&2 || true
        fail "$label: unexpected $mode output (diff above: want vs got)"
    fi
}

test_write_through() {
    local d="$WORK/wt" before
    echo "== write_through =="
    mkdir -p "$d/real" "$d/mid" "$d/home"
    printf 'old\n' > "$d/real/file"
    chmod 640 "$d/real/file"
    ln -s ../real/file "$d/mid/file"
    ln -s ../mid/file "$d/home/file"
    printf 'new\n' | write_through "$d/home/file"
    [ -L "$d/home/file" ] && [ -L "$d/mid/file" ] || fail "a link in the chain was replaced"
    [ "$(cat "$d/real/file")" = "new" ] || fail "the end of the chain was not written"
    [ "$(mode_of "$d/real/file")" = "640" ] || fail "mode changed to $(mode_of "$d/real/file")"
    [ -z "$(find "$d/real" -name 'file.*')" ] || fail "temp files left behind"
    pass "writes go through relative symlink chains and keep the mode"

    printf 'created\n' | write_through "$d/home/created"
    [ -f "$d/home/created" ] && [ "$(cat "$d/home/created")" = "created" ] || fail "a missing target was not created"
    [ -z "$(find "$d/home" -name 'created.*')" ] || fail "temp files left behind after creating a file"
    pass "a missing target is created"

    if [ "$(id -u)" -ne 0 ]; then
        mkdir -p "$d/ro"
        printf 'keep\n' > "$d/ro/file"
        before="$(cksum < "$d/ro/file")"
        chmod 555 "$d/ro"
        set +e
        printf 'lost\n' | write_through "$d/ro/file" 2>/dev/null
        local rc=$?
        set -e
        chmod 755 "$d/ro"
        [ "$rc" -ne 0 ] || fail "write_through reported success in a read-only directory"
        [ "$(cksum < "$d/ro/file")" = "$before" ] || fail "the original changed although the write failed"
        pass "a failed write leaves the original untouched"
    else
        echo "SKIP: root ignores directory permissions"
    fi
}

test_replace() {
    echo "== toml_edit_server replace =="

    cat > "$IN" <<TOML
model = "gpt-5"

[mcp_servers."activity-mesh"]
command = "node"
args = ["/old/server.mjs"]

# keep: config for the github server
[mcp_servers.github]
command = "gh-server"
TOML
    cat > "$WANT" <<TOML
model = "gpt-5"

$BLOCK

# keep: config for the github server
[mcp_servers.github]
command = "gh-server"
TOML
    expect "comment above the next table" replace 0
    pass "the comment that introduces the next table survives, blank lines are kept as they were"

    cat > "$IN" <<TOML
model = "x"

$BLOCK
TOML
    cp "$IN" "$WANT"
    expect "an up-to-date table at the end of the file" replace 0
    pass "replacing an up-to-date table at the end of the file reproduces it byte for byte"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/old/server.mjs"]
TOML
    cat > "$WANT" <<TOML
$BLOCK
TOML
    expect "table is the whole file" replace 0
    pass "a table that is the whole file is replaced"

    cat > "$IN" <<TOML
a = 1
[ mcp_servers . 'activity-mesh' ]  # mine
command = "node"
[mcp_servers.other]
b = 2
TOML
    cat > "$WANT" <<TOML
a = 1
$BLOCK
[mcp_servers.other]
b = 2
TOML
    expect "spelled with quotes, spaces and a comment" replace 0
    pass "a header written with single quotes, spaces and a trailing comment is recognised"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "one"

[mcp_servers.x]
y = 1

[mcp_servers."activity-mesh"]
command = "two"

# tail comment
TOML
    cat > "$WANT" <<TOML
$BLOCK

[mcp_servers.x]
y = 1


# tail comment
TOML
    expect "duplicates" replace 0
    pass "a duplicated table collapses into one, neighbours and comments stay"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = [
  "/old/server.mjs",
  "--flag",
]

[mcp_servers.activity-mesh.env]
FOO = "bar"

[mcp_servers.after]
x = 1
TOML
    cat > "$WANT" <<TOML
$BLOCK

[mcp_servers.activity-mesh.env]
FOO = "bar"

[mcp_servers.after]
x = 1
TOML
    expect "multi-line array and sub-table" replace 0
    pass "a multi-line block is replaced whole while its sub-table and later tables stay"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh-other]
command = "other"

[[mcp_servers.activity-mesh.extra]]
k = 1
TOML
    cp "$IN" "$WANT"
    expect "look-alike names" replace 1
    pass "look-alike names and array-of-tables are not mistaken for the table"

    printf 'model = "x"\r\n\r\n[mcp_servers.activity-mesh]\r\ncommand = "node"\r\n\r\n# next\r\n[mcp_servers.n]\r\nz = 1\r\n' > "$IN"
    printf 'model = "x"\r\n\r\n%s\n\r\n# next\r\n[mcp_servers.n]\r\nz = 1\r\n' "$BLOCK" > "$WANT"
    expect "CRLF file" replace 0
    pass "CRLF lines around the table are left as they were"

    printf 'model = "x"\n\n[mcp_servers.activity-mesh]\ncommand = "node"' > "$IN"
    printf 'model = "x"\n\n%s\n' "$BLOCK" > "$WANT"
    expect "no trailing newline" replace 0
    pass "a table on an unterminated last line is replaced"

    cat > "$IN" <<TOML
["mcp_servers"."activity-mesh"]
command = "node"
args = ["/old/server.mjs"]

['mcp_servers'."activity-mesh".env]
FOO = "bar"
TOML
    cat > "$WANT" <<TOML
$BLOCK

['mcp_servers'."activity-mesh".env]
FOO = "bar"
TOML
    expect "quoted parent key" replace 0
    toml_ok "$GOT" || fail "quoted parent key: the result is not valid TOML: $(cat "$GOT")"
    pass "a header with the parent key quoted is replaced in place, not duplicated"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh.env]
FOO = "bar"

[mcp_servers.activity-mesh]
command = "old"
TOML
    cat > "$WANT" <<TOML
[mcp_servers.activity-mesh.env]
FOO = "bar"

$BLOCK
TOML
    expect "sub-table before the table" replace 0
    toml_ok "$GOT" || fail "sub-table before the table: the result is not valid TOML: $(cat "$GOT")"
    pass "a sub-table that precedes the table stays where it is while the table is replaced"
}

test_defines_elsewhere() {
    local label want found
    echo "== toml_defines_elsewhere =="
    probe() {
        want="$1"; label="$2"; shift 2
        printf '%s\n' "$@" > "$IN"
        if toml_defines_elsewhere "$IN" > "$GOT"; then found=yes; else found=no; fi
        [ "$found" = "$want" ] || fail "$label: expected $want, got $found"
    }
    probe yes "dotted keys under [mcp_servers]" 'model = "o3"' '' '[mcp_servers]' 'activity-mesh.command = "node"' 'activity-mesh.args = ["/old/server.mjs"]'
    [ "$(cat "$GOT")" = "4" ] || fail "the line number of the first dotted key: $(cat "$GOT")"
    probe yes "inline table under [mcp_servers]" '[mcp_servers]' 'activity-mesh = { command = "node", args = ["/old/server.mjs"] }'
    probe yes "quoted key with spaces around the dot" '[mcp_servers]' '  "activity-mesh" . command = "node"'
    probe yes "single-quoted key, inline, no spaces" '[ mcp_servers ]' "'activity-mesh'={command='node'}"
    probe yes "quoted parent header" '["mcp_servers"]' 'activity-mesh.command = "x"'
    probe yes "top-level dotted keys" 'model = "o3"' 'mcp_servers.activity-mesh.command = "node"'
    probe yes "top-level dotted keys, quoted" '"mcp_servers"."activity-mesh".command = "node"'
    probe yes "top-level inline table, only entry" 'mcp_servers = { activity-mesh = { command = "node", args = ["/x"] } }'
    probe yes "top-level inline table, later entry" 'mcp_servers = { other = { command = "o" }, "activity-mesh" = { command = "node" } }'
    probe yes "top-level dotted inline table" 'mcp_servers.activity-mesh = { command = "node" }'
    pass "dotted keys and inline tables that define the server are found, in every quoting"

    probe no "a plain table" '[mcp_servers.activity-mesh]' 'command = "node"'
    probe no "a project path that ends in activity-mesh" 'model = "x"' '[projects."/home/u/Projects/activity-mesh"]' 'trust_level = "trusted"'
    probe no "another server that mentions activity-mesh in its args" '[mcp_servers.other]' 'args = ["/home/u/activity-mesh/mcp/server.mjs"]'
    probe no "a key that only starts with the name" '[mcp_servers]' 'activity-mesh-extra = { command = "node" }'
    probe no "commented out keys" '[mcp_servers]' '# activity-mesh.command = "node"' 'other.command = "x"'
    probe no "the key inside another server's table" '[mcp_servers.other]' 'activity-mesh = 1'
    probe no "the key in an unrelated table" '[tools]' 'activity-mesh = true'
    probe no "an inline table of another server" 'mcp_servers = { other = { command = "o" } }'
    probe no "a sub-table on its own" '[mcp_servers.activity-mesh.env]' 'FOO = "bar"'
    probe no "an empty file" ''
    pass "tables, look-alikes, comments and other servers are not mistaken for a definition"
}

test_strip() {
    echo "== toml_edit_server strip =="

    cat > "$IN" <<TOML
model = "gpt-5"

[mcp_servers."activity-mesh"]
command = "node"
args = ["/h/.local/share/activity-mesh/dist/current/mcp/server.mjs"]

[mcp_servers."activity-mesh".env]
FOO = "bar"

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    cat > "$WANT" <<TOML
model = "gpt-5"

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    expect "main and sub-table" strip 0
    pass "the table and its sub-tables go, the comment above the next table stays, no blank lines pile up"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/repo/mcp/server.mjs"]

# note
[mcp_servers.other]
a = 1
TOML
    cp "$IN" "$WANT"
    expect "points elsewhere" strip 1
    pass "a table that does not point into dist is left alone"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
# args = ["/c/.local/share/activity-mesh/dist/old.mjs"]
args = ["/repo/mcp/server.mjs"]  # was /h/.local/share/activity-mesh/dist/x.mjs
TOML
    cp "$IN" "$WANT"
    expect "dist only in comments" strip 1
    pass "a mention of dist inside a comment does not count"

    cat > "$IN" <<TOML
a = 1

[mcp_servers.activity-mesh]
command = "node"
args = ["/c/.local/share/activity-mesh/dist/current/mcp/server.mjs"]

TOML
    cat > "$WANT" <<TOML
a = 1

TOML
    expect "second needle, table at the end" strip 0
    pass "the second needle matches too, and a table at the end of the file leaves no stray blank lines behind it"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/repo/mcp/server.mjs"]

[mcp_servers.activity-mesh.env]
PATH = "/h/.local/share/activity-mesh/dist/bin"
TOML
    cp "$IN" "$WANT"
    expect "only the sub-table points into dist" strip 1
    pass "a sub-table that points into dist, under a table that does not, is left for the caller to report"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh.env]
PATH = "/h/.local/share/activity-mesh/dist/bin"

[mcp_servers.activity-mesh]
command = "node"
args = ["/repo/mcp/server.mjs"]
TOML
    cp "$IN" "$WANT"
    expect "sub-table first, only it points into dist" strip 1
    pass "the order of a table and its sub-table makes no difference when the table is not ours"

    cat > "$IN" <<TOML
model = "gpt-5"

[mcp_servers.activity-mesh.env]
FOO = "bar"

[mcp_servers.activity-mesh]
command = "node"
args = ["/h/.local/share/activity-mesh/dist/current/mcp/server.mjs"]

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    cat > "$WANT" <<TOML
model = "gpt-5"

# the other server
[mcp_servers.other]
command = "other-server"
TOML
    expect "sub-table before the table" strip 0
    toml_ok "$GOT" || fail "sub-table before the table: the result is not valid TOML: $(cat "$GOT")"
    if grep -q 'activity-mesh' "$GOT"; then fail "a sub-table placed before its table survived: $(cat "$GOT")"; fi
    pass "a sub-table placed before the table goes with it, and what is left is valid TOML"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/h/.local/share/activity-mesh/dist/current/mcp/server.mjs"]

[[mcp_servers.activity-mesh.tools]]
name = "a"

[[mcp_servers.activity-mesh.tools]]
name = "b"

[mcp_servers.other]
x = 1
TOML
    cat > "$WANT" <<TOML
[mcp_servers.other]
x = 1
TOML
    expect "array-of-tables below the table" strip 0
    toml_ok "$GOT" || fail "array-of-tables: the result is not valid TOML: $(cat "$GOT")"
    pass "an array-of-tables under the table goes with it"

    cat > "$IN" <<TOML
[[mcp_servers.activity-mesh.tools]]
name = "a"

["mcp_servers"."activity-mesh"]
command = "node"
args = ["/c/.local/share/activity-mesh/dist/x.mjs"]

['mcp_servers'.'activity-mesh'.env]
FOO = "bar"

[mcp_servers.keep]
y = 2
TOML
    cat > "$WANT" <<TOML
[mcp_servers.keep]
y = 2
TOML
    expect "quoted parent keys" strip 0
    toml_ok "$GOT" || fail "quoted parent keys: the result is not valid TOML: $(cat "$GOT")"
    pass "a header with the parent key quoted, in either quote style, is the table too"

    cat > "$IN" <<TOML
[mcp_servers.activity-mesh]
args = ["/h/.local/share/activity-mesh/dist/a.mjs"]

[mcp_servers.keep]
args = ["/h/.local/share/activity-mesh/dist/not-ours.mjs"]

[mcp_servers."activity-mesh"]
args = ["/c/.local/share/activity-mesh/dist/b.mjs"]
TOML
    cat > "$WANT" <<TOML
[mcp_servers.keep]
args = ["/h/.local/share/activity-mesh/dist/not-ours.mjs"]

TOML
    expect "duplicates and a neighbour in dist" strip 0
    pass "every copy of the table goes; another server that points into dist is not this scanner's business"
}

fs_id() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"; }

test_paths() {
    local d="$WORK/paths" base up fl lp ids
    echo "== path helpers =="
    mkdir -p "$d/Real/Sub" "$d/other"
    ln -s Real "$d/link"
    base="$(cd -P "$d" && /bin/pwd -P)"

    [ "$(norm_lex "/a//b///")" = "/a/b" ] && [ "$(norm_lex "//")" = "/" ] && [ "$(norm_lex "/a/./b/")" = "/a/./b" ] || fail "norm_lex"
    pass "norm_lex collapses slashes and strips trailing ones, nothing more"

    [ "$(canon_path "$d/link/Sub/../Sub/")" = "$base/Real/Sub" ] || fail "canon_path through a symlink and dots: $(canon_path "$d/link/Sub/../Sub/")"
    [ "$(canon_path "$d/link/new/dir")" = "$base/Real/new/dir" ] || fail "canon_path of a missing tail: $(canon_path "$d/link/new/dir")"
    [ "$(canon_path "/")" = "/" ] || fail "canon_path of /"
    pass "canon_path resolves symlinks and dots, and keeps the tail of a path that does not exist yet"

    up="$(printf '%s' "$d/Real" | tr 'a-z' 'A-Z')"
    if [ -d "$up" ] && [ "$(fs_id "$up")" = "$(fs_id "$d/Real")" ]; then
        [ "$(canon_path "$up")" = "$base/Real" ] || fail "canon_path kept an upper-case spelling: $(canon_path "$up")"
        [ "$(canon_path "$d/REAL/")" = "$base/Real" ] || fail "canon_path kept a spelling that differs in the last component: $(canon_path "$d/REAL/")"
        pass "on a case-insensitive filesystem every case spelling canonicalizes to the stored name"
    else
        echo "SKIP: case-sensitive filesystem"
    fi

    fl="/System/Volumes/Data$base/Real"
    if [ -d "/System/Volumes/Data" ] && [ -d "$fl" ] && [ "$(fs_id "$fl")" = "$(fs_id "$d/Real")" ]; then
        [ "$(canon_path "$fl")" = "$base/Real" ] || fail "canon_path kept the firmlink spelling: $(canon_path "$fl")"
        pass "the /System/Volumes/Data spelling canonicalizes to the usual path"
    else
        echo "SKIP: no firmlink spelling on this system"
    fi
    case "$base" in
        /private/*)
            lp="/PRIVATE${base#/private}/Real"
            if [ -d "$lp" ] && [ "$(fs_id "$lp")" = "$(fs_id "$d/Real")" ]; then
                [ "$(canon_path "$lp")" = "$base/Real" ] || fail "canon_path kept /PRIVATE: $(canon_path "$lp")"
                pass "/PRIVATE canonicalizes to /private"
            fi ;;
    esac

    [ "$(dir_id "$d/link")" = "$(dir_id "$d/Real")" ] || fail "dir_id does not follow a symlink"
    [ "$(dir_id "$d/Real")" != "$(dir_id "$d/other")" ] || fail "dir_id equal for two directories"
    if dir_id "$d/missing" >/dev/null 2>&1; then fail "dir_id succeeded for a missing path"; fi
    pass "dir_id is the device:inode of what a path resolves to, and fails for what does not exist"

    ids="$(chain_ids "$d/link/Sub")"
    grep -qxF "$(dir_id "$d")" <<< "$ids" || fail "chain_ids misses a parent"
    grep -qxF "$(dir_id /)" <<< "$ids" || fail "chain_ids misses /"
    grep -qxF "$(dir_id "$d/Real/Sub")" <<< "$ids" || fail "chain_ids misses the path itself"
    ids="$(chain_ids "$d/missing/deeper")"
    [ "${ids%%$'\n'*}" = "$(dir_id "$d")" ] || fail "chain_ids does not skip components that do not exist"
    pass "chain_ids lists the identity of a path and of every parent, skipping what does not exist"

    covers / /a && covers /a /a && covers /a /a/b && covers /a/b /a/b/c || fail "covers misses a containment"
    if covers /a/b /a || covers /a /ab || covers /a/b /a/bc; then fail "covers reports a containment that is not one"; fi
    pass "covers is path containment, not a string prefix"
}

test_trim() {
    echo "== trim_ws =="
    [ "$(trim_ws "  a b  ")" = "a b" ] && [ "$(trim_ws $'\t/x/y\t')" = "/x/y" ] && [ "$(trim_ws $'\n x \n')" = "x" ] \
        && [ -z "$(trim_ws "   ")" ] && [ -z "$(trim_ws "")" ] && [ "$(trim_ws x)" = "x" ] && [ "$(trim_ws " a  b ")" = "a  b" ] \
        || fail "trim_ws"
    pass "trim_ws strips blanks at both ends and nothing else"
}

test_json() {
    local d="$WORK/json" out_lib out_boot rc_lib rc_boot input
    echo "== sync_dir from config.json =="
    mkdir -p "$d"
    printf '{\n  "sync_dir": "/Users/x/Dropbox/activity",\n  "store_dir": "/s"\n}\n' > "$d/plain.json"
    [ "$(config_sync_dir "$d/plain.json")" = "/Users/x/Dropbox/activity" ] || fail "plain sync_dir"
    printf '{"sync_dir": "/Users/x/R\\u0026D/a\\\\b\\"c", "store_dir": "/s"}\n' > "$d/escaped.json"
    [ "$(config_sync_dir "$d/escaped.json")" = '/Users/x/R&D/a\b"c' ] || fail "escaped sync_dir: $(config_sync_dir "$d/escaped.json")"
    printf '{"sync_dir": "", "store_dir": "/s"}\n' > "$d/empty.json"
    [ -z "$(config_sync_dir "$d/empty.json")" ] || fail "empty sync_dir"
    printf '{"store_dir": "/s"}\n' > "$d/nokey.json"
    [ -z "$(config_sync_dir "$d/nokey.json")" ] || fail "missing key"
    [ -z "$(config_sync_dir "$d/missing.json")" ] || fail "missing file"
    printf '{"sync_dir": "/a\\tb"}\n' > "$d/tab.json"
    if config_sync_dir "$d/tab.json" >/dev/null; then fail "an escape that cannot be decoded was accepted"; fi
    pass "config_sync_dir reads sync_dir, decodes the escapes bootstrap decodes, and refuses the rest"

    sed -n '/^json_unescape() {/,/^}/p' "$REPO_ROOT/installers/bootstrap.sh" > "$d/bootstrap_unescape.sh"
    [ -s "$d/bootstrap_unescape.sh" ] || fail "could not extract json_unescape from bootstrap.sh"
    for input in 'plain' '' 'a\\b' 'a\"b' 'R&D' '<x>' 'q\\\"r' '\n' 'tab\t' 'é' 'trailing\' 'x\\' '\\\\'; do
        set +e
        out_lib="$(bash -c '. "$1"; json_unescape "$2"' _ "$REPO_ROOT/installers/lib/cfgedit.sh" "$input")"; rc_lib=$?
        out_boot="$(bash -c '. "$1"; json_unescape "$2"' _ "$d/bootstrap_unescape.sh" "$input")"; rc_boot=$?
        set -e
        [ "$rc_lib" = "$rc_boot" ] && [ "$out_lib" = "$out_boot" ] || fail "json_unescape diverges from bootstrap.sh on [$input]: lib rc=$rc_lib [$out_lib], bootstrap rc=$rc_boot [$out_boot]"
    done
    pass "json_unescape decodes exactly what bootstrap.sh's own copy decodes"
}

test_write_through
test_paths
test_trim
test_json
test_replace
test_strip
test_defines_elsewhere

echo
echo "ALL CFGEDIT TESTS PASSED"
