#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/amesh-integration-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sum_of() { cksum < "$1"; }
count_of() { grep -c -- "$1" "$2" || true; }

mkdir -p "$WORK/tmp" "$WORK/tools" "$WORK/shim"
TOOLS="$WORK/tools"
SHIM="$WORK/shim"
for t in node jq python3; do
    tool_path="$(command -v "$t" 2>/dev/null || true)"
    if [ -n "$tool_path" ]; then ln -s "$tool_path" "$TOOLS/$t"; fi
done
for c in claude launchctl systemctl sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/shim.log"\nexit 0\n' "$c" "$WORK" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
BASE_PATH="$TOOLS:/usr/bin:/bin"
HOME_UNDER_TEST=""
RUN_PATH="$SHIM:$BASE_PATH"
RC=0

sandbox() { env -i HOME="$HOME_UNDER_TEST" PATH="$RUN_PATH" TMPDIR="$WORK/tmp" "$@"; }
run_capture() { local out="$1"; shift; set +e; "$@" > "$out" 2>&1; RC=$?; set -e; }
have() { [ -x "$TOOLS/$1" ]; }
toml_ok() {
    have python3 || return 0
    "$TOOLS/python3" -c 'import tomllib' 2>/dev/null || return 0
    "$TOOLS/python3" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1"
}
CODEX_BIN="$(command -v codex 2>/dev/null || true)"
codex_loads() {
    env -i HOME="$1" CODEX_HOME="$1/.codex" PATH="$(dirname "$CODEX_BIN"):/usr/bin:/bin" TMPDIR="$WORK/tmp" "$CODEX_BIN" mcp list > /dev/null 2>&1
}
codex_usable() {
    [ -n "$CODEX_BIN" ] || return 1
    mkdir -p "$WORK/codex-baseline/home/.codex"
    : > "$WORK/codex-baseline/home/.codex/config.toml"
    codex_loads "$WORK/codex-baseline/home"
}

seed_claude_md() {
    printf '%b' '# Rules\n\n## Memory canonical sources (x)\n\n| a | b |\n|---|---|\n\n## Next section\n\ntext\n' > "$1"
}
marker_before_next_section() {
    awk '/activity-mesh:integration:end/{e=NR} /^## Next section/{n=NR} END{exit !(e && n && e<n)}' "$1"
}

test_integration_install() {
    local d="$WORK/a" b="$WORK/b" c="$WORK/c" before out
    echo "== integration/install.sh writes through symlinks and keeps modes =="
    mkdir -p "$d/dotfiles" "$d/home/.claude"
    seed_claude_md "$d/dotfiles/CLAUDE.md"
    chmod 640 "$d/dotfiles/CLAUDE.md"
    ln -s "$d/dotfiles/CLAUDE.md" "$d/home/.claude/CLAUDE.md"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"
    run_capture "$d/out.txt" sandbox CLAUDE_MD="$d/home/.claude/CLAUDE.md" bash "$REPO_ROOT/integration/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out.txt" >&2; fail "integration/install.sh exited $RC on a symlinked CLAUDE.md"; }
    [ -L "$d/home/.claude/CLAUDE.md" ] || fail "the CLAUDE.md symlink was replaced by a regular file"
    [ "$(readlink "$d/home/.claude/CLAUDE.md")" = "$d/dotfiles/CLAUDE.md" ] || fail "the CLAUDE.md symlink now points elsewhere"
    grep -qF 'activity-mesh:integration:end' "$d/dotfiles/CLAUDE.md" || fail "the symlink target was not patched"
    marker_before_next_section "$d/dotfiles/CLAUDE.md" || fail "the block was not placed before the next section"
    [ "$(mode_of "$d/dotfiles/CLAUDE.md")" = "640" ] || fail "target mode changed to $(mode_of "$d/dotfiles/CLAUDE.md")"
    [ -z "$(find "$d/dotfiles" -name 'CLAUDE.md.*')" ] || fail "temp files left next to the target: $(find "$d/dotfiles" -name 'CLAUDE.md.*')"
    [ -n "$(find "$d/home/.claude" -name 'CLAUDE.md.bak-*')" ] || fail "no backup written"
    pass "a symlinked CLAUDE.md is patched in its target, link and mode intact"

    before="$(sum_of "$d/dotfiles/CLAUDE.md")"
    run_capture "$d/out2.txt" sandbox CLAUDE_MD="$d/home/.claude/CLAUDE.md" bash "$REPO_ROOT/integration/install.sh"
    [ "$RC" -eq 0 ] || fail "second run exited $RC"
    grep -q 'already patched' "$d/out2.txt" || fail "second run did not report 'already patched': $(cat "$d/out2.txt")"
    [ "$(sum_of "$d/dotfiles/CLAUDE.md")" = "$before" ] || fail "second run changed the file"
    pass "a second run is a no-op"

    mkdir -p "$b/real" "$b/mid" "$b/home/.claude"
    seed_claude_md "$b/real/CLAUDE.md"
    chmod 600 "$b/real/CLAUDE.md"
    ln -s ../real/CLAUDE.md "$b/mid/CLAUDE.md"
    ln -s ../../mid/CLAUDE.md "$b/home/.claude/CLAUDE.md"
    HOME_UNDER_TEST="$b/home"
    run_capture "$b/out.txt" sandbox CLAUDE_MD="$b/home/.claude/CLAUDE.md" bash "$REPO_ROOT/integration/install.sh"
    [ "$RC" -eq 0 ] || { cat "$b/out.txt" >&2; fail "exit $RC on a chain of relative symlinks"; }
    [ -L "$b/home/.claude/CLAUDE.md" ] && [ -L "$b/mid/CLAUDE.md" ] || fail "a link in the chain was replaced"
    grep -qF 'activity-mesh:integration:end' "$b/real/CLAUDE.md" || fail "the end of a relative symlink chain was not patched"
    [ "$(mode_of "$b/real/CLAUDE.md")" = "600" ] || fail "mode of the chain target changed to $(mode_of "$b/real/CLAUDE.md")"
    pass "a chain of relative symlinks is followed to the real file"

    mkdir -p "$c/home/.claude"
    seed_claude_md "$c/home/.claude/CLAUDE.md"
    chmod 644 "$c/home/.claude/CLAUDE.md"
    HOME_UNDER_TEST="$c/home"
    run_capture "$c/out.txt" sandbox CLAUDE_MD="$c/home/.claude/CLAUDE.md" bash "$REPO_ROOT/integration/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC on a regular CLAUDE.md"
    [ "$(mode_of "$c/home/.claude/CLAUDE.md")" = "644" ] || fail "a regular file's mode changed to $(mode_of "$c/home/.claude/CLAUDE.md")"
    pass "a regular CLAUDE.md keeps its mode"

    printf '# my rules\n' > "$d/plain.md"
    HOME_UNDER_TEST="/home/alice.smith"
    run_capture "$d/out-mem.txt" sandbox CLAUDE_MD="$d/plain.md" bash "$REPO_ROOT/integration/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out-mem.txt" >&2; fail "exit $RC on a CLAUDE.md without the memory section"; }
    grep -qF 'projects/-home-alice-smith/memory/MEMORY.md' "$d/plain.md" \
        || fail "the memory path is not derived from HOME: $(grep MEMORY.md "$d/plain.md" | head -1)"
    if grep -q 'maksimkravcov' "$d/plain.md"; then fail "the author's home leaked into the written block"; fi
    pass "the MEMORY.md path comes from HOME, not from the author's"

    printf '# my rules\n' > "$d/untouched.md"
    before="$(sum_of "$d/untouched.md")"
    out="$(sandbox CLAUDE_MD="$d/untouched.md" bash "$REPO_ROOT/integration/install.sh" --help 2>&1)"
    case "$out" in usage:*) ;; *) fail "--help does not print a usage line: $out" ;; esac
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || fail "--help printed more than one line: $out"
    [ "$(sum_of "$d/untouched.md")" = "$before" ] || fail "--help modified the target"
    run_capture "$d/out-bad.txt" sandbox CLAUDE_MD="$d/untouched.md" bash "$REPO_ROOT/integration/install.sh" --dryrun
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
    [ "$(sum_of "$d/untouched.md")" = "$before" ] || fail "an unknown flag modified the target"
    run_capture "$d/out-dry.txt" sandbox CLAUDE_MD="$d/untouched.md" bash "$REPO_ROOT/integration/install.sh" --dry-run
    [ "$RC" -eq 0 ] || fail "--dry-run exited $RC"
    grep -q 'DRY RUN' "$d/out-dry.txt" || fail "--dry-run printed no diff"
    [ "$(sum_of "$d/untouched.md")" = "$before" ] || fail "--dry-run modified the target"
    pass "--help prints one usage line, an unknown flag is refused, --dry-run writes nothing"
}

test_hooks_install() {
    local d="$WORK/h" before out s p
    echo "== hooks/install.sh writes through symlinks and keeps modes =="
    mkdir -p "$d/dotfiles" "$d/home/.claude"
    printf '%s\n' '{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/keep-me.sh"}]}]}}' > "$d/dotfiles/settings.json"
    chmod 600 "$d/dotfiles/settings.json"
    ln -s "$d/dotfiles/settings.json" "$d/home/.claude/settings.json"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"
    run_capture "$d/out.txt" sandbox CLAUDE_SETTINGS="$d/home/.claude/settings.json" bash "$REPO_ROOT/hooks/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out.txt" >&2; fail "hooks/install.sh exited $RC on a symlinked settings.json"; }
    [ -L "$d/home/.claude/settings.json" ] || fail "the settings.json symlink was replaced by a regular file"
    [ "$(readlink "$d/home/.claude/settings.json")" = "$d/dotfiles/settings.json" ] || fail "the settings.json symlink now points elsewhere"
    s="$REPO_ROOT/hooks/session-start-digest.sh"
    p="$REPO_ROOT/hooks/user-prompt-router.sh"
    "$TOOLS/jq" -e --arg s "$s" '[.hooks.SessionStart[].hooks[].command] | index($s) != null' "$d/dotfiles/settings.json" >/dev/null \
        || fail "the SessionStart hook is missing from the symlink target"
    "$TOOLS/jq" -e --arg p "$p" '[.hooks.UserPromptSubmit[].hooks[].command] | index($p) != null' "$d/dotfiles/settings.json" >/dev/null \
        || fail "the UserPromptSubmit hook is missing from the symlink target"
    "$TOOLS/jq" -e '.theme == "dark" and .hooks.PreToolUse[0].hooks[0].command == "/opt/keep-me.sh"' "$d/dotfiles/settings.json" >/dev/null \
        || fail "existing settings were not preserved"
    [ "$("$TOOLS/jq" -r 'keys_unsorted | first' "$d/dotfiles/settings.json")" = "theme" ] || fail "key order was not preserved"
    [ "$(mode_of "$d/dotfiles/settings.json")" = "600" ] || fail "target mode changed to $(mode_of "$d/dotfiles/settings.json")"
    [ -z "$(find "$d/dotfiles" -name 'settings.json.*')" ] || fail "temp files left next to the target"
    [ -n "$(find "$d/home/.claude" -name 'settings.json.bak-*')" ] || fail "no backup written"
    pass "a symlinked settings.json is patched in its target, link, mode and key order intact"

    before="$(sum_of "$d/dotfiles/settings.json")"
    run_capture "$d/out2.txt" sandbox CLAUDE_SETTINGS="$d/home/.claude/settings.json" bash "$REPO_ROOT/hooks/install.sh"
    [ "$RC" -eq 0 ] || fail "second run exited $RC"
    grep -q 'already wired' "$d/out2.txt" || fail "second run did not report 'already wired': $(cat "$d/out2.txt")"
    [ "$(sum_of "$d/dotfiles/settings.json")" = "$before" ] || fail "second run changed the file"
    pass "a second run is a no-op"

    printf '{"hooks":{}}\n' > "$d/plain.json"
    chmod 644 "$d/plain.json"
    run_capture "$d/out-plain.txt" sandbox CLAUDE_SETTINGS="$d/plain.json" bash "$REPO_ROOT/hooks/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC on a regular settings.json"
    [ "$(mode_of "$d/plain.json")" = "644" ] || fail "a regular file's mode changed to $(mode_of "$d/plain.json")"
    pass "a regular settings.json keeps its mode"

    printf '{"hooks":{}}\n' > "$d/untouched.json"
    before="$(sum_of "$d/untouched.json")"
    out="$(sandbox CLAUDE_SETTINGS="$d/untouched.json" bash "$REPO_ROOT/hooks/install.sh" --help 2>&1)"
    case "$out" in usage:*) ;; *) fail "--help does not print a usage line: $out" ;; esac
    run_capture "$d/out-bad.txt" sandbox CLAUDE_SETTINGS="$d/untouched.json" bash "$REPO_ROOT/hooks/install.sh" --dryrun
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
    [ "$(sum_of "$d/untouched.json")" = "$before" ] || fail "--help or an unknown flag modified settings.json"
    pass "--help prints a usage line and an unknown flag is refused without touching settings.json"
}

test_session_end_flush() {
    local d="$WORK/f" hook before out
    echo "== update-session-end-flush.sh writes through symlinks and keeps modes =="
    mkdir -p "$d/home/.claude/hooks" "$d/dotfiles"
    hook="$d/home/.claude/hooks/session-end-flush.sh"
    printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$hook"
    chmod 755 "$hook"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"
    run_capture "$d/out.txt" sandbox bash "$REPO_ROOT/integration/update-session-end-flush.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out.txt" >&2; fail "update-session-end-flush.sh exited $RC"; }
    [ "$(mode_of "$hook")" = "755" ] || fail "hook mode changed to $(mode_of "$hook")"
    grep -qF '# activity-mesh: emit session-summary event' "$hook" || fail "hook was not patched"
    bash -n "$hook" || fail "patched hook is not valid bash"
    awk '/activity-mesh: emit session-summary event/{e=NR} /^mv "\$STAGE_OUT"/{m=NR} END{exit !(e && m && e<m)}' "$hook" \
        || fail "the injected block is not before the mv line"
    pass "a regular hook is patched and stays executable with its original mode"

    before="$(sum_of "$hook")"
    run_capture "$d/out2.txt" sandbox bash "$REPO_ROOT/integration/update-session-end-flush.sh"
    grep -q 'already patched' "$d/out2.txt" || fail "second run did not report 'already patched'"
    [ "$(sum_of "$hook")" = "$before" ] || fail "second run changed the hook"
    pass "a second run is a no-op"

    printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$d/dotfiles/flush.sh"
    chmod 750 "$d/dotfiles/flush.sh"
    ln -s "$d/dotfiles/flush.sh" "$d/home/.claude/hooks/linked-flush.sh"
    run_capture "$d/out3.txt" sandbox SESSION_END_HOOK="$d/home/.claude/hooks/linked-flush.sh" bash "$REPO_ROOT/integration/update-session-end-flush.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out3.txt" >&2; fail "exit $RC on a symlinked hook"; }
    [ -L "$d/home/.claude/hooks/linked-flush.sh" ] || fail "the hook symlink was replaced by a regular file"
    grep -qF '# activity-mesh: emit session-summary event' "$d/dotfiles/flush.sh" || fail "the symlink target was not patched"
    [ "$(mode_of "$d/dotfiles/flush.sh")" = "750" ] || fail "target mode changed to $(mode_of "$d/dotfiles/flush.sh")"
    pass "a symlinked hook is patched in its target"

    printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$d/untouched.sh"
    before="$(sum_of "$d/untouched.sh")"
    out="$(sandbox SESSION_END_HOOK="$d/untouched.sh" bash "$REPO_ROOT/integration/update-session-end-flush.sh" --help 2>&1)"
    case "$out" in usage:*) ;; *) fail "--help does not print a usage line: $out" ;; esac
    run_capture "$d/out-bad.txt" sandbox SESSION_END_HOOK="$d/untouched.sh" bash "$REPO_ROOT/integration/update-session-end-flush.sh" --dryrun
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
    [ "$(sum_of "$d/untouched.sh")" = "$before" ] || fail "--help or an unknown flag modified the hook"
    pass "--help prints a usage line and an unknown flag is refused without touching the hook"
}

expect_codex_refused() {
    local d="$1" label="$2" server="$REPO_ROOT/mcp/server.mjs" cfg before baks
    cfg="$d/home/.codex/config.toml"
    before="$(sum_of "$cfg")"
    baks="$(find "$d/home/.codex" -name '*.bak-*' | wc -l | tr -d ' ')"
    : > "$WORK/shim.log"
    run_capture "$d/out-refused.txt" sandbox bash "$REPO_ROOT/mcp/install.sh" ${3:+"$3"}
    [ "$RC" -ne 0 ] || { cat "$d/out-refused.txt" >&2; fail "$label: mcp/install.sh must exit non-zero"; }
    [ "$(sum_of "$cfg")" = "$before" ] || fail "$label: config.toml was modified: $(cat "$cfg")"
    [ "$(find "$d/home/.codex" -name '*.bak-*' | wc -l | tr -d ' ')" = "$baks" ] || fail "$label: a backup was written"
    grep -q 'WARN' "$d/out-refused.txt" && grep -q 'by hand' "$d/out-refused.txt" || fail "$label: no warning: $(cat "$d/out-refused.txt")"
    grep -qF 'command = ' "$d/out-refused.txt" || fail "$label: the block to paste is not shown: $(cat "$d/out-refused.txt")"
    if [ -z "${3:-}" ]; then
        grep -qxF "claude mcp add activity-mesh --scope user -- $TOOLS/node $server" "$WORK/shim.log" \
            || fail "$label: the Claude registration was skipped after the Codex refusal: $(cat "$WORK/shim.log")"
    fi
}

test_mcp_install() {
    local d="$WORK/m" server="$REPO_ROOT/mcp/server.mjs" cfg before out hdr baks
    echo "== mcp/install.sh =="
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"
    mkdir -p "$d/home/.codex" "$d/dotfiles"
    cfg="$d/home/.codex/config.toml"

    out="$(sandbox bash "$REPO_ROOT/mcp/install.sh" --help 2>&1)"
    [ "$out" = "usage: install.sh [--dry-run]" ] || fail "--help must print the usage line only, got: $out"
    run_capture "$d/out-bad.txt" sandbox bash "$REPO_ROOT/mcp/install.sh" --dryrun
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
    pass "--help prints the usage line, not the script source"

    printf '%s\n' 'model = "gpt-5"' '' '[mcp_servers."activity-mesh"]' 'command = "node"' 'args = ["/old/path/server.mjs"]' '' '[mcp_servers.other]' 'command = "other-server"' > "$cfg"
    chmod 640 "$cfg"
    run_capture "$d/out.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out.txt" >&2; fail "mcp/install.sh exited $RC"; }
    [ "$(count_of 'mcp_servers\..*activity-mesh' "$cfg")" = "1" ] || fail "expected exactly one activity-mesh table: $(cat "$cfg")"
    grep -qF "args = [\"$server\"]" "$cfg" || fail "args were not updated to $server: $(cat "$cfg")"
    grep -qF "command = \"$TOOLS/node\"" "$cfg" || fail "command was not updated to the node on PATH: $(cat "$cfg")"
    if grep -qF '/old/path' "$cfg"; then fail "the old path survived: $(cat "$cfg")"; fi
    grep -qF 'model = "gpt-5"' "$cfg" && grep -qF '[mcp_servers.other]' "$cfg" && grep -qF 'command = "other-server"' "$cfg" \
        || fail "unrelated config was not preserved: $(cat "$cfg")"
    [ "$(mode_of "$cfg")" = "640" ] || fail "config mode changed to $(mode_of "$cfg")"
    toml_ok "$cfg" || fail "config.toml is not valid TOML: $(cat "$cfg")"
    baks="$(find "$d/home/.codex" -name 'config.toml.bak-*')"
    [ -n "$baks" ] && grep -qF '/old/path' "$baks" || fail "no backup holding the previous config"
    pass "an existing [mcp_servers.\"activity-mesh\"] table is replaced in place, not duplicated"

    before="$(sum_of "$cfg")"
    run_capture "$d/out2.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "second run exited $RC"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "second run changed config.toml"
    grep -q 'already up to date' "$d/out2.txt" || fail "second run did not report 'already up to date': $(grep -i codex -A1 "$d/out2.txt")"
    [ "$(find "$d/home/.codex" -name 'config.toml.bak-*' | wc -l | tr -d ' ')" = "1" ] || fail "second run wrote another backup"
    pass "a second run leaves config.toml untouched"

    for hdr in '[mcp_servers.activity-mesh]' "[mcp_servers.'activity-mesh']" '[ mcp_servers . "activity-mesh" ]  # mine' '["mcp_servers"."activity-mesh"]' "['mcp_servers'.\"activity-mesh\"]"; do
        printf '%s\n' "$hdr" 'command = "node"' 'args = ["/old/path/server.mjs"]' > "$cfg"
        run_capture "$d/out-hdr.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
        [ "$RC" -eq 0 ] || fail "exit $RC for header $hdr"
        [ "$(count_of 'mcp_servers.*activity-mesh' "$cfg")" = "1" ] || fail "header $hdr: expected one table, got: $(cat "$cfg")"
        grep -qF "args = [\"$server\"]" "$cfg" || fail "header $hdr: args not updated: $(cat "$cfg")"
        if grep -qF '/old/path' "$cfg"; then fail "header $hdr: old path survived"; fi
        toml_ok "$cfg" || fail "header $hdr: invalid TOML: $(cat "$cfg")"
    done
    pass "every spelling of the table header is recognised"

    printf '%s\n' '[mcp_servers.activity-mesh]' 'command = "node"' 'args = [' '  "/old/path/server.mjs",' '  "--flag",' ']' '' '[mcp_servers.activity-mesh.env]' 'FOO = "bar"' '' '[mcp_servers.after]' 'x = 1' > "$cfg"
    run_capture "$d/out-multi.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC on a multi-line args array"
    if grep -qF -- '--flag' "$cfg"; then fail "the multi-line args array survived: $(cat "$cfg")"; fi
    grep -qF '[mcp_servers.activity-mesh.env]' "$cfg" && grep -qF 'FOO = "bar"' "$cfg" || fail "the env sub-table was lost: $(cat "$cfg")"
    grep -qF '[mcp_servers.after]' "$cfg" && grep -qF 'x = 1' "$cfg" || fail "the table after the block was lost: $(cat "$cfg")"
    toml_ok "$cfg" || fail "invalid TOML after replacing a multi-line block: $(cat "$cfg")"
    pass "a multi-line block is replaced whole; sub-tables and later tables survive"

    printf 'model = "x"' > "$cfg"
    chmod 600 "$cfg"
    run_capture "$d/out-app.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC when appending"
    [ "$(count_of 'mcp_servers\..*activity-mesh' "$cfg")" = "1" ] || fail "append: expected one table: $(cat "$cfg")"
    [ "$(head -1 "$cfg")" = 'model = "x"' ] || fail "append: existing content changed: $(cat "$cfg")"
    [ "$(mode_of "$cfg")" = "600" ] || fail "append: mode changed to $(mode_of "$cfg")"
    toml_ok "$cfg" || fail "append: invalid TOML: $(cat "$cfg")"
    pass "a missing table is appended after an unterminated last line"

    printf '%s\n' 'model = "gpt-5"' '' '[mcp_servers."activity-mesh"]' 'command = "node"' 'args = ["/old/path/server.mjs"]' '' '# keep: config for the github server' '[mcp_servers.github]' 'command = "gh-server"' > "$cfg"
    run_capture "$d/out-comment.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC when a comment follows the table"
    [ "$(grep -B1 -xF '[mcp_servers.github]' "$cfg" | head -1)" = '# keep: config for the github server' ] \
        || fail "the comment above [mcp_servers.github] was dropped: $(cat "$cfg")"
    grep -qF 'command = "gh-server"' "$cfg" || fail "the next table lost its content: $(cat "$cfg")"
    toml_ok "$cfg" || fail "invalid TOML: $(cat "$cfg")"
    pass "a comment that introduces the next table survives a replace"

    printf 'model = "x"\n' > "$cfg"
    run_capture "$d/out-fresh.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC on a fresh append"
    before="$(sum_of "$cfg")"
    baks="$(find "$d/home/.codex" -name 'config.toml.bak-*' | wc -l | tr -d ' ')"
    run_capture "$d/out-fresh2.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC on the re-run after a fresh append"
    [ "$(sum_of "$cfg")" = "$before" ] || fail "the re-run rewrote a config that was just appended: $(cat "$cfg")"
    grep -q 'already up to date' "$d/out-fresh2.txt" || fail "the re-run did not report 'already up to date'"
    [ "$(find "$d/home/.codex" -name 'config.toml.bak-*' | wc -l | tr -d ' ')" = "$baks" ] || fail "the re-run wrote a backup"
    pass "an append followed by a re-run is a no-op, with no backup"

    printf 'model = "x"\n' > "$d/dotfiles/append.toml"
    chmod 640 "$d/dotfiles/append.toml"
    rm -f "$cfg"
    ln -s "$d/dotfiles/append.toml" "$cfg"
    baks="$(find "$d/home/.codex" "$d/dotfiles" -name '*.bak-*' | wc -l | tr -d ' ')"
    run_capture "$d/out-append-link.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC appending through a symlink"
    [ -L "$cfg" ] || fail "the config.toml symlink was replaced by a regular file"
    grep -qF '[mcp_servers.activity-mesh]' "$d/dotfiles/append.toml" || fail "the table was not appended to the symlink target"
    [ "$(mode_of "$d/dotfiles/append.toml")" = "640" ] || fail "target mode changed to $(mode_of "$d/dotfiles/append.toml")"
    [ -z "$(find "$d/dotfiles" -name 'append.toml.*')" ] || fail "temp files left next to the target"
    [ "$(find "$d/home/.codex" "$d/dotfiles" -name '*.bak-*' | wc -l | tr -d ' ')" = "$baks" ] || fail "an append wrote a backup although it only adds lines"
    rm -f "$cfg"
    run_capture "$d/out-create.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC creating a missing config.toml"
    [ -f "$cfg" ] && [ ! -L "$cfg" ] && grep -qF '[mcp_servers.activity-mesh]' "$cfg" || fail "a missing config.toml was not created"
    [ -z "$(find "$d/home/.codex" -name 'config.toml.*' ! -name 'config.toml.bak-*')" ] || fail "temp files left behind"
    toml_ok "$cfg" || fail "invalid TOML: $(cat "$cfg")"
    pass "an append is written atomically, through symlinks, with no temp files or backups left"

    if [ "$(id -u)" -ne 0 ]; then
        printf 'model = "x"\n' > "$cfg"
        before="$(sum_of "$cfg")"
        chmod 555 "$d/home/.codex"
        run_capture "$d/out-readonly.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
        chmod 755 "$d/home/.codex"
        [ "$(sum_of "$cfg")" = "$before" ] || fail "config.toml changed although its directory is read-only: $(cat "$cfg")"
        grep -q 'WARN' "$d/out-readonly.txt" || fail "no warning when the config cannot be written: $(cat "$d/out-readonly.txt")"
        pass "when the config cannot be replaced atomically it is left untouched, with a warning"
    else
        echo "SKIP: root ignores directory permissions"
    fi

    printf '%s\n' '[mcp_servers."activity-mesh"]' 'command = "node"' 'args = ["/old/path/server.mjs"]' > "$d/dotfiles/codex.toml"
    chmod 640 "$d/dotfiles/codex.toml"
    rm -f "$cfg"
    ln -s "$d/dotfiles/codex.toml" "$cfg"
    run_capture "$d/out-link.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out-link.txt" >&2; fail "exit $RC on a symlinked config.toml"; }
    [ -L "$cfg" ] || fail "the config.toml symlink was replaced by a regular file"
    grep -qF "args = [\"$server\"]" "$d/dotfiles/codex.toml" || fail "the symlink target was not updated: $(cat "$d/dotfiles/codex.toml")"
    [ "$(mode_of "$d/dotfiles/codex.toml")" = "640" ] || fail "target mode changed to $(mode_of "$d/dotfiles/codex.toml")"
    [ -z "$(find "$d/dotfiles" -name 'codex.toml.*')" ] || fail "temp files left next to the target"
    pass "a symlinked config.toml is rewritten in its target"

    printf '%s\n' '[mcp_servers."activity-mesh"]' 'command = "node"' 'args = ["/old/path/server.mjs"]' > "$d/dotfiles/codex.toml"
    before="$(sum_of "$d/dotfiles/codex.toml")"
    run_capture "$d/out-dry.txt" sandbox bash "$REPO_ROOT/mcp/install.sh" --dry-run
    [ "$RC" -eq 0 ] || fail "--dry-run exited $RC"
    [ "$(sum_of "$d/dotfiles/codex.toml")" = "$before" ] || fail "--dry-run modified config.toml"
    grep -q 'would replace the existing' "$d/out-dry.txt" || fail "--dry-run does not announce the replacement: $(cat "$d/out-dry.txt")"
    pass "--dry-run announces the replacement and writes nothing"

    : > "$WORK/shim.log"
    run_capture "$d/out-claude.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || fail "exit $RC with the claude shim on PATH"
    grep -qxF "claude mcp remove activity-mesh --scope user" "$WORK/shim.log" || fail "claude mcp remove not called: $(cat "$WORK/shim.log")"
    grep -qxF "claude mcp add activity-mesh --scope user -- $TOOLS/node $server" "$WORK/shim.log" \
        || fail "claude mcp add not called with the server path: $(cat "$WORK/shim.log")"
    pass "with the claude CLI on PATH the server is registered through claude mcp add"

    if have jq; then
        printf '%s\n' '{"other":1,"mcpServers":{"x":{"command":"y"}}}' > "$d/dotfiles/claude.json"
        chmod 600 "$d/dotfiles/claude.json"
        ln -s "$d/dotfiles/claude.json" "$d/home/.claude.json"
        RUN_PATH="$BASE_PATH"
        run_capture "$d/out-jq.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
        RUN_PATH="$SHIM:$BASE_PATH"
        [ "$RC" -eq 0 ] || { cat "$d/out-jq.txt" >&2; fail "exit $RC on the jq fallback"; }
        [ -L "$d/home/.claude.json" ] || fail "the ~/.claude.json symlink was replaced by a regular file"
        "$TOOLS/jq" -e --arg s "$server" '.mcpServers["activity-mesh"].args[0] == $s and .mcpServers.x.command == "y" and .other == 1' "$d/dotfiles/claude.json" >/dev/null \
            || fail "the jq fallback did not update the symlink target: $(cat "$d/dotfiles/claude.json")"
        [ "$(mode_of "$d/dotfiles/claude.json")" = "600" ] || fail "target mode changed to $(mode_of "$d/dotfiles/claude.json")"
        pass "without the claude CLI the jq fallback writes through ~/.claude.json symlinks"
    else
        skip "jq not found — jq fallback not exercised"
    fi

    rm -f "$cfg"
    printf '%s\n' 'model = "o3"' '' '[mcp_servers]' 'activity-mesh.command = "node"' 'activity-mesh.args = ["/old/path/server.mjs"]' > "$cfg"
    expect_codex_refused "$d" "dotted keys under [mcp_servers]"
    grep -q 'line 4' "$d/out-refused.txt" || fail "the refusal does not name the line of the definition: $(cat "$d/out-refused.txt")"
    printf '%s\n' '[mcp_servers]' 'activity-mesh = { command = "node", args = ["/old/path/server.mjs"] }' > "$cfg"
    expect_codex_refused "$d" "an inline table under [mcp_servers]"
    printf '%s\n' 'mcp_servers = { activity-mesh = { command = "node", args = ["/old/path/server.mjs"] } }' > "$cfg"
    expect_codex_refused "$d" "a top-level inline table"
    printf '%s\n' 'mcp_servers.activity-mesh.command = "node"' > "$cfg"
    expect_codex_refused "$d" "top-level dotted keys"
    pass "a server defined as dotted keys or an inline table is not defined a second time: non-zero exit, the block to paste, nothing written, the other runtimes still wired"

    printf '%s\n' '[mcp_servers]' 'activity-mesh = { command = "node" }' > "$cfg"
    expect_codex_refused "$d" "--dry-run on an inline table" --dry-run
    pass "--dry-run reports the same refusal in its exit code and writes nothing"

    printf '%s\n' 'model = "x"' '' '[projects."/home/u/Projects/activity-mesh"]' 'trust_level = "trusted"' > "$cfg"
    run_capture "$d/out-proj.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out-proj.txt" >&2; fail "a project path that ends in activity-mesh was mistaken for a definition (rc $RC)"; }
    grep -qxF '[mcp_servers.activity-mesh]' "$cfg" || fail "the table was not appended: $(cat "$cfg")"
    [ "$(count_of '^\[projects' "$cfg")" = "1" ] || fail "the project table was lost: $(cat "$cfg")"
    toml_ok "$cfg" || fail "invalid TOML: $(cat "$cfg")"
    pass "a project whose path ends in activity-mesh is not mistaken for a definition"

    printf '%s\n' '[mcp_servers.activity-mesh.env]' 'FOO = "bar"' > "$cfg"
    run_capture "$d/out-subonly.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
    [ "$RC" -eq 0 ] || { cat "$d/out-subonly.txt" >&2; fail "a lone sub-table stopped the install (rc $RC)"; }
    grep -qxF '[mcp_servers.activity-mesh]' "$cfg" && grep -qxF '[mcp_servers.activity-mesh.env]' "$cfg" || fail "table or sub-table missing: $(cat "$cfg")"
    toml_ok "$cfg" || fail "a table added after its sub-table is not valid TOML: $(cat "$cfg")"
    pass "a lone sub-table does not stop the table from being added"

    if codex_usable; then
        codex_loads "$d/home" || fail "codex refuses to load a config with a table added after its sub-table: $(cat "$cfg")"
        printf '%s\n' '["mcp_servers"."activity-mesh"]' 'command = "node"' 'args = ["/old/path/server.mjs"]' > "$cfg"
        run_capture "$d/out-codex.txt" sandbox bash "$REPO_ROOT/mcp/install.sh"
        [ "$RC" -eq 0 ] || fail "exit $RC replacing a quoted-parent table"
        codex_loads "$d/home" || fail "codex refuses to load the replaced quoted-parent table: $(cat "$cfg")"
        pass "the real codex loads what the installer wrote"
    else
        skip "codex is not usable here — its own loader was not consulted"
    fi
}

test_conflict_free() {
    local d="$WORK/e" home key memdir out
    echo "== integration/test-conflict-free.sh reads the MEMORY.md of the running user =="
    mkdir -p "$d/home" "$d/shim"
    home="$d/home"
    key="$(printf '%s' "$home" | tr -c 'A-Za-z0-9' '-')"
    memdir="$home/.claude/projects/$key/memory"
    mkdir -p "$memdir"
    printf '# memory\n' > "$memdir/MEMORY.md"
    cat > "$d/shim/activity-log" <<'SHIM'
#!/bin/sh
case "$1" in
    status|init) exit 0 ;;
    emit)
        shift
        summary=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "--summary" ]; then summary="$2"; fi
            shift
        done
        printf '%s\n' "$summary" > "$AMESH_SHIM_STATE/summary"
        if [ -n "${AMESH_SHIM_LEAK:-}" ]; then printf '%s\n' "$summary" >> "$AMESH_SHIM_LEAK"; fi
        echo 01ARZ3NDEKTSV4RRFFQ69G5FAV
        ;;
    query) cat "$AMESH_SHIM_STATE/summary" ;;
esac
SHIM
    printf '#!/bin/sh\nexit 7\n' > "$d/shim/curl"
    printf '#!/bin/sh\nexit 0\n' > "$d/shim/sleep"
    chmod +x "$d/shim/activity-log" "$d/shim/curl" "$d/shim/sleep"

    set +e
    env -i HOME="$home" PATH="$d/shim:/usr/bin:/bin" TMPDIR="$WORK/tmp" AMESH_SHIM_STATE="$d" \
        bash "$REPO_ROOT/integration/test-conflict-free.sh" > "$d/out.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -eq 0 ] || { cat "$d/out.txt" >&2; fail "the conflict-free check exited $RC on a clean MEMORY.md"; }
    grep -q 'MEMORY.md has no nonce' "$d/out.txt" || fail "MEMORY.md of this HOME was not checked: $(cat "$d/out.txt")"
    pass "the leak check finds MEMORY.md under the running user's project key"

    set +e
    env -i HOME="$home" PATH="$d/shim:/usr/bin:/bin" TMPDIR="$WORK/tmp" AMESH_SHIM_STATE="$d" AMESH_SHIM_LEAK="$memdir/MEMORY.md" \
        bash "$REPO_ROOT/integration/test-conflict-free.sh" > "$d/out-leak.txt" 2>&1
    RC=$?
    set -e
    [ "$RC" -eq 1 ] || { cat "$d/out-leak.txt" >&2; fail "a nonce leaked into MEMORY.md but the check exited $RC"; }
    grep -q 'MEMORY.md contains nonce' "$d/out-leak.txt" || fail "the leak was not reported: $(cat "$d/out-leak.txt")"
    pass "a nonce leaked into MEMORY.md is reported"
}

test_no_author_paths() {
    local hits
    echo "== no author-specific paths in the install scripts =="
    hits="$(grep -ln 'maksimkravcov' "$REPO_ROOT"/integration/*.sh "$REPO_ROOT"/hooks/*.sh "$REPO_ROOT"/mcp/*.sh "$REPO_ROOT"/installers/*.sh 2>/dev/null || true)"
    [ -z "$hits" ] || fail "the author's user path is hardcoded in: $hits"
    pass "no script hardcodes the author's home"
}

test_single_helper() {
    local defs
    echo "== the write-through helper is defined once, in installers/lib/cfgedit.sh =="
    defs="$(grep -rl '^write_through()' "$REPO_ROOT/integration" "$REPO_ROOT/hooks" "$REPO_ROOT/mcp" "$REPO_ROOT/installers" 2>/dev/null | sed "s|^$REPO_ROOT/||" | sort | tr '\n' ' ')"
    [ "$defs" = "installers/lib/cfgedit.sh " ] || fail "write_through is defined in: $defs"
    pass "no install script carries its own copy of write_through"
}

test_missing_helper() {
    local d="$WORK/nolib" settings_sum claude_sum hook_sum out
    echo "== a script run without installers/lib refuses before touching anything =="
    mkdir -p "$d/hooks" "$d/integration" "$d/mcp" "$d/home"
    cp "$REPO_ROOT/hooks/install.sh" "$d/hooks/install.sh"
    cp "$REPO_ROOT/integration/install.sh" "$d/integration/install.sh"
    cp "$REPO_ROOT/integration/update-session-end-flush.sh" "$d/integration/update-session-end-flush.sh"
    cp "$REPO_ROOT/mcp/install.sh" "$d/mcp/install.sh"
    : > "$d/mcp/server.mjs"
    printf '{"hooks":{}}\n' > "$d/settings.json"
    printf '# my rules\n' > "$d/CLAUDE.md"
    printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$d/hook.sh"
    settings_sum="$(sum_of "$d/settings.json")"
    claude_sum="$(sum_of "$d/CLAUDE.md")"
    hook_sum="$(sum_of "$d/hook.sh")"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"

    run_capture "$d/out-hooks.txt" sandbox CLAUDE_SETTINGS="$d/settings.json" bash "$d/hooks/install.sh"
    [ "$RC" -ne 0 ] && grep -q 'cfgedit.sh' "$d/out-hooks.txt" || fail "hooks/install.sh did not refuse without its helper (rc=$RC): $(cat "$d/out-hooks.txt")"
    [ "$(sum_of "$d/settings.json")" = "$settings_sum" ] || fail "hooks/install.sh touched settings.json without its helper"

    run_capture "$d/out-integration.txt" sandbox CLAUDE_MD="$d/CLAUDE.md" bash "$d/integration/install.sh"
    [ "$RC" -ne 0 ] && grep -q 'cfgedit.sh' "$d/out-integration.txt" || fail "integration/install.sh did not refuse without its helper (rc=$RC): $(cat "$d/out-integration.txt")"
    [ "$(sum_of "$d/CLAUDE.md")" = "$claude_sum" ] || fail "integration/install.sh touched CLAUDE.md without its helper"

    run_capture "$d/out-flush.txt" sandbox SESSION_END_HOOK="$d/hook.sh" bash "$d/integration/update-session-end-flush.sh"
    [ "$RC" -ne 0 ] && grep -q 'cfgedit.sh' "$d/out-flush.txt" || fail "update-session-end-flush.sh did not refuse without its helper (rc=$RC): $(cat "$d/out-flush.txt")"
    [ "$(sum_of "$d/hook.sh")" = "$hook_sum" ] || fail "update-session-end-flush.sh touched the hook without its helper"

    run_capture "$d/out-mcp.txt" sandbox bash "$d/mcp/install.sh"
    [ "$RC" -ne 0 ] && grep -q 'cfgedit.sh' "$d/out-mcp.txt" || fail "mcp/install.sh did not refuse without its helper (rc=$RC): $(cat "$d/out-mcp.txt")"
    [ ! -e "$d/home/.codex" ] && [ ! -e "$d/home/.claude.json" ] || fail "mcp/install.sh wrote configuration without its helper"

    out="$(sandbox bash "$d/hooks/install.sh" --help 2>&1)"
    case "$out" in usage:*) ;; *) fail "--help must work without the helper: $out" ;; esac
    pass "every install script names the missing helper and changes nothing; --help still works"
}

test_symlinked_scripts() {
    local d="$WORK/sl" tree="$WORK/sl/tree" dist="$WORK/sl/dist-tree" f cmd
    echo "== a script started through a symlink finds its helper and registers its own directory =="
    mkdir -p "$tree/hooks" "$tree/installers/lib" "$tree/integration" "$tree/mcp" "$d/bin" "$d/home/.claude" "$d/home/.codex"
    for f in hooks/install.sh hooks/session-start-digest.sh hooks/user-prompt-router.sh installers/lib/cfgedit.sh \
             integration/install.sh integration/update-session-end-flush.sh mcp/install.sh; do
        cp "$REPO_ROOT/$f" "$tree/$f"
        chmod +x "$tree/$f"
    done
    : > "$tree/mcp/server.mjs"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"

    if have jq; then
        printf '{"hooks":{}}\n' > "$d/settings.json"
        ln -s "$tree/hooks/install.sh" "$d/bin/hooks-install"
        ln -s hooks-install "$d/bin/hooks-install-chain"
        run_capture "$d/out-hooks.txt" sandbox CLAUDE_SETTINGS="$d/settings.json" bash "$d/bin/hooks-install-chain"
        [ "$RC" -eq 0 ] || { cat "$d/out-hooks.txt" >&2; fail "hooks/install.sh exited $RC through a chain of symlinks"; }
        cmd="$("$TOOLS/jq" -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings.json")"
        [ "$cmd" = "$tree/hooks/session-start-digest.sh" ] || fail "the SessionStart hook was registered as $cmd, not under the script's own directory"
        pass "hooks/install.sh through a chain of symlinks registers the hooks next to the real script"

        mkdir -p "$dist/dist/0.4.0"
        cp -R "$tree/hooks" "$tree/installers" "$dist/dist/0.4.0/"
        ln -s 0.4.0 "$dist/dist/current"
        printf '{"hooks":{}}\n' > "$d/settings-current.json"
        ln -s "$dist/dist/current/hooks/install.sh" "$d/bin/hooks-install-current"
        run_capture "$d/out-current.txt" sandbox CLAUDE_SETTINGS="$d/settings-current.json" bash "$d/bin/hooks-install-current"
        [ "$RC" -eq 0 ] || { cat "$d/out-current.txt" >&2; fail "hooks/install.sh exited $RC through a link into dist/current"; }
        cmd="$("$TOOLS/jq" -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings-current.json")"
        [ "$cmd" = "$dist/dist/current/hooks/session-start-digest.sh" ] || fail "the hook path lost its dist/current spelling: $cmd"
        printf '{"hooks":{}}\n' > "$d/settings-direct.json"
        run_capture "$d/out-direct.txt" sandbox CLAUDE_SETTINGS="$d/settings-direct.json" bash "$dist/dist/current/hooks/install.sh"
        cmd="$("$TOOLS/jq" -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings-direct.json")"
        [ "$cmd" = "$dist/dist/current/hooks/session-start-digest.sh" ] || fail "run from dist/current directly, the hook path lost its spelling: $cmd"
        pass "a registered hook path keeps the dist/current spelling, which survives upgrades"
    else
        skip "jq not found — hooks/install.sh not exercised"
    fi

    if have python3; then
        seed_claude_md "$d/CLAUDE.md"
        ln -s ../tree/integration/install.sh "$d/bin/integration-install"
        run_capture "$d/out-integration.txt" sandbox CLAUDE_MD="$d/CLAUDE.md" bash "$d/bin/integration-install"
        [ "$RC" -eq 0 ] || { cat "$d/out-integration.txt" >&2; fail "integration/install.sh exited $RC through a relative symlink"; }
        grep -qF 'activity-mesh:integration:end' "$d/CLAUDE.md" || fail "integration/install.sh through a symlink did not patch the target"
        printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$d/hook.sh"
        ln -s "$tree/integration/update-session-end-flush.sh" "$d/bin/flush-update"
        run_capture "$d/out-flush.txt" sandbox SESSION_END_HOOK="$d/hook.sh" bash "$d/bin/flush-update"
        [ "$RC" -eq 0 ] || { cat "$d/out-flush.txt" >&2; fail "update-session-end-flush.sh exited $RC through a symlink"; }
        grep -qF '# activity-mesh: emit session-summary event' "$d/hook.sh" || fail "update-session-end-flush.sh through a symlink did not patch the hook"
        pass "integration/install.sh and update-session-end-flush.sh find their helper through a symlink"
    else
        skip "python3 not found — integration/install.sh not exercised"
    fi

    if have node; then
        : > "$WORK/shim.log"
        ln -s "$tree/mcp/install.sh" "$d/bin/mcp-install"
        run_capture "$d/out-mcp.txt" sandbox bash "$d/bin/mcp-install"
        [ "$RC" -eq 0 ] || { cat "$d/out-mcp.txt" >&2; fail "mcp/install.sh exited $RC through a symlink"; }
        grep -qxF "claude mcp add activity-mesh --scope user -- $TOOLS/node $tree/mcp/server.mjs" "$WORK/shim.log" \
            || fail "mcp/install.sh through a symlink registered another server path: $(cat "$WORK/shim.log")"
        pass "mcp/install.sh through a symlink registers the server that sits next to the real script"
    else
        skip "node not found — mcp/install.sh not exercised"
    fi
}

test_decoy_layout() {
    local d="$WORK/p5" real="$WORK/p5/dotfiles/tree" decoy="$WORK/p5/tree" f cmd real_p
    echo "== a link reached through a symlinked directory is resolved where the link lives, not where its path says =="
    mkdir -p "$real/hooks" "$real/installers/lib" "$real/integration" "$real/mcp" \
             "$decoy/hooks" "$decoy/installers/lib" "$decoy/integration" "$decoy/mcp" "$d/dotfiles/bin" "$d/home/.claude" "$d/home/.codex"
    for f in hooks/install.sh hooks/session-start-digest.sh hooks/user-prompt-router.sh installers/lib/cfgedit.sh \
             integration/install.sh integration/update-session-end-flush.sh mcp/install.sh; do
        cp "$REPO_ROOT/$f" "$real/$f"
        chmod +x "$real/$f"
    done
    : > "$real/mcp/server.mjs"
    printf '%s\n' 'echo DECOY-HELPER-SOURCED >&2' 'exit 97' > "$decoy/installers/lib/cfgedit.sh"
    : > "$decoy/hooks/session-start-digest.sh"
    : > "$decoy/hooks/user-prompt-router.sh"
    ln -s ../tree/hooks/install.sh "$d/dotfiles/bin/hooks-install"
    ln -s ../tree/integration/install.sh "$d/dotfiles/bin/integration-install"
    ln -s ../tree/integration/update-session-end-flush.sh "$d/dotfiles/bin/flush-update"
    ln -s ../tree/mcp/install.sh "$d/dotfiles/bin/mcp-install"
    ln -s dotfiles/bin "$d/bin"
    real_p="$(cd -P "$real" && pwd)"
    HOME_UNDER_TEST="$d/home"; RUN_PATH="$SHIM:$BASE_PATH"

    if have jq; then
        printf '{"hooks":{}}\n' > "$d/settings.json"
        run_capture "$d/out-hooks.txt" sandbox CLAUDE_SETTINGS="$d/settings.json" bash "$d/bin/hooks-install"
        [ "$RC" -eq 0 ] || { cat "$d/out-hooks.txt" >&2; fail "hooks/install.sh exited $RC through a symlinked directory with a decoy at the path's own location"; }
        cmd="$("$TOOLS/jq" -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings.json")"
        [ "$cmd" = "$real_p/hooks/session-start-digest.sh" ] || fail "the hook was registered as $cmd instead of under $real_p"
        printf '{"hooks":{}}\n' > "$d/settings-dotdot.json"
        run_capture "$d/out-dotdot.txt" sandbox CLAUDE_SETTINGS="$d/settings-dotdot.json" bash "$d/bin/../tree/hooks/install.sh"
        [ "$RC" -eq 0 ] || { cat "$d/out-dotdot.txt" >&2; fail "hooks/install.sh exited $RC when started by a path that goes through a symlinked directory and .."; }
        cmd="$("$TOOLS/jq" -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings-dotdot.json")"
        [ "$cmd" = "$real_p/hooks/session-start-digest.sh" ] || fail "started through <symlinked dir>/../tree/hooks the hook was registered as $cmd instead of under $real_p"
        pass "hooks/install.sh registers the hooks next to the real script, not next to a look-alike directory"
    else
        skip "jq not found — hooks/install.sh not exercised"
    fi
    if have python3; then
        seed_claude_md "$d/CLAUDE.md"
        run_capture "$d/out-integration.txt" sandbox CLAUDE_MD="$d/CLAUDE.md" bash "$d/bin/integration-install"
        [ "$RC" -eq 0 ] || { cat "$d/out-integration.txt" >&2; fail "integration/install.sh exited $RC through a symlinked directory with a decoy"; }
        grep -qF 'activity-mesh:integration:end' "$d/CLAUDE.md" || fail "integration/install.sh did not patch the target"
        printf '#!/bin/bash\nSTAGE_OUT=a\nOUT=b\nmv "$STAGE_OUT" "$OUT"\n' > "$d/hook.sh"
        run_capture "$d/out-flush.txt" sandbox SESSION_END_HOOK="$d/hook.sh" bash "$d/bin/flush-update"
        [ "$RC" -eq 0 ] || { cat "$d/out-flush.txt" >&2; fail "update-session-end-flush.sh exited $RC through a symlinked directory with a decoy"; }
        grep -qF '# activity-mesh: emit session-summary event' "$d/hook.sh" || fail "update-session-end-flush.sh did not patch the hook"
        pass "integration/install.sh and update-session-end-flush.sh source the helper next to the real script"
    else
        skip "python3 not found — integration scripts not exercised"
    fi
    if have node; then
        : > "$WORK/shim.log"
        run_capture "$d/out-mcp.txt" sandbox bash "$d/bin/mcp-install"
        [ "$RC" -eq 0 ] || { cat "$d/out-mcp.txt" >&2; fail "mcp/install.sh exited $RC through a symlinked directory with a decoy"; }
        grep -qxF "claude mcp add activity-mesh --scope user -- $TOOLS/node $real_p/mcp/server.mjs" "$WORK/shim.log" \
            || fail "mcp/install.sh registered another server path: $(cat "$WORK/shim.log")"
        pass "mcp/install.sh registers the server that sits next to the real script"
    else
        skip "node not found — mcp/install.sh not exercised"
    fi
}

if have python3; then test_integration_install; else skip "python3 not found — integration/install.sh needs it"; fi
if have jq; then test_hooks_install; else skip "jq not found — hooks/install.sh needs it"; fi
if have python3; then test_session_end_flush; else skip "python3 not found — update-session-end-flush.sh needs it"; fi
if have node; then test_mcp_install; else skip "node not found — mcp/install.sh needs it"; fi
test_conflict_free
test_no_author_paths
test_single_helper
test_missing_helper
test_symlinked_scripts
test_decoy_layout

echo
echo "ALL INTEGRATION INSTALL TESTS PASSED"
