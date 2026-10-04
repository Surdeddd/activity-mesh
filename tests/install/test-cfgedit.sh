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
    cat > "$WANT" <<TOML
[mcp_servers.activity-mesh]
command = "node"
args = ["/repo/mcp/server.mjs"]

TOML
    expect "only the sub-table points into dist" strip 0
    pass "a sub-table that points into dist is dropped on its own"

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

test_write_through
test_replace
test_strip

echo
echo "ALL CFGEDIT TESTS PASSED"
