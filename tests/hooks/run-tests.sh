#!/bin/bash
# Regression tests for the Claude Code hooks:
#   hooks/user-prompt-router.sh   (UserPromptSubmit)
#   hooks/session-start-digest.sh (SessionStart)
#
# These hooks run on every prompt / session start and have silently broken
# before (stale binary path, removed CLI flags). The suite pins:
#   - exit code 0 in EVERY case (non-zero would block the user's prompt)
#   - exact activity-log query args per intent class
#   - graceful silent skip when the binary is missing
#   - resilience to malformed stdin and to jq missing from PATH
#     (hooks call /usr/bin/jq by absolute path — the launchd-context property)
#
# Plain bash, no test framework. Each case runs the hook via `env -i` with a
# fresh temp HOME, a minimal controlled PATH, and a stub activity-log injected
# through ACTIVITY_MESH_BIN that records its argv for exact-match assertions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$REPO_ROOT/hooks/user-prompt-router.sh"
DIGEST="$REPO_ROOT/hooks/session-start-digest.sh"

# jq for assertions (same absolute path the hooks themselves use).
JQ="/usr/bin/jq"
if [ ! -x "$JQ" ]; then
    JQ="$(command -v jq)" || { echo "jq is required to run assertions" >&2; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/activity-mesh-hook-tests.XXXXXX")" || exit 2
# Router writes per-session token budgets to /tmp (outside HOME) — clean ours.
trap 'rm -rf "$WORK"; rm -f /tmp/activity-tokens-hooktest-*' EXIT

# Controlled PATHs. Hooks resolve jq/tr/head/cut via absolute /usr/bin paths,
# but need cat/date/mkdir from PATH. MINPATH deliberately has NO jq, proving
# the hooks survive launchd-style environments where jq is not on PATH.
MINPATH="$WORK/minpath"
FULLPATH="$WORK/fullpath"
mkdir -p "$MINPATH" "$FULLPATH"
for tool in cat date mkdir; do
    bin=""
    for cand in "/bin/$tool" "/usr/bin/$tool"; do
        if [ -x "$cand" ]; then bin="$cand"; break; fi
    done
    [ -n "$bin" ] || { echo "cannot locate required tool: $tool" >&2; exit 2; }
    ln -s "$bin" "$MINPATH/$tool"
    ln -s "$bin" "$FULLPATH/$tool"
done
ln -s "$JQ" "$FULLPATH/jq"

# Stub activity-log: records argv (one line per invocation) to $STUB_ARGV,
# prints $STUB_OUTPUT (if non-empty) as the fake query result.
STUB="$WORK/activity-log"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_ARGV:?}"
if [ -n "${STUB_OUTPUT:-}" ]; then printf '%s\n' "$STUB_OUTPUT"; fi
exit 0
EOF
chmod +x "$STUB"

# ---------------------------------------------------------------- harness ---
PASS=0
FAIL=0
CASE_N=0
CASE=""
ERRORS=""
HOMEDIR=""
ARGV_FILE=""
RC=0
OUT=""
CTX=""

begin_case() {
    CASE="$1"
    ERRORS=""
    CASE_N=$((CASE_N + 1))
    HOMEDIR="$WORK/home-$CASE_N"
    mkdir -p "$HOMEDIR"
    ARGV_FILE="$HOMEDIR/stub-argv"
}

err() { ERRORS="${ERRORS}      - $1"$'\n'; }

end_case() {
    if [ -z "$ERRORS" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$CASE"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n%s' "$CASE" "$ERRORS"
    fi
}

# run <hook> <stdin> [VAR=VAL ...] — run hook isolated: env -i, fresh HOME,
# controlled PATH (extra VAR=VAL args may override, e.g. PATH or stub config).
run() {
    local hook="$1" stdin="$2"
    shift 2
    printf '%s' "$stdin" | env -i HOME="$HOMEDIR" PATH="$FULLPATH" STUB_ARGV="$ARGV_FILE" "$@" \
        /bin/bash "$hook" > "$HOMEDIR/stdout" 2> "$HOMEDIR/stderr"
    RC=$?
    OUT="$(cat "$HOMEDIR/stdout")"
}

# JSON stdin builders (unique session ids keep /tmp token files isolated).
pj() { printf '{"prompt":"%s","session_id":"hooktest-%s-%s"}' "$1" "$$" "$2"; }
sj() { printf '{"session_id":"hooktest-%s-%s"}' "$$" "$1"; }

assert_rc0() { [ "$RC" -eq 0 ] || err "exit code $RC — hook must ALWAYS exit 0"; }

assert_silent() { [ -z "$OUT" ] || err "expected no stdout, got: $OUT"; }

assert_stub_not_called() {
    [ ! -s "$ARGV_FILE" ] || err "stub was invoked: $(cat "$ARGV_FILE")"
}

assert_argv() {
    local expected="$1" got
    if [ ! -s "$ARGV_FILE" ]; then err "stub never invoked"; return; fi
    got="$(cat "$ARGV_FILE")"
    [ "$got" = "$expected" ] || \
        err "stub argv: got [${got//$'\n'/ | }] want [${expected//$'\n'/ | }]"
}

# assert_emits <hookEventName> <ctx-substring>... — stdout must be valid hook
# JSON; additionalContext must contain every given substring. Sets $CTX.
assert_emits() {
    local event="$1" ev sub
    shift
    CTX=""
    if [ -z "$OUT" ]; then err "expected hook JSON on stdout, got nothing"; return; fi
    if ! ev="$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"; then
        err "stdout is not valid JSON: $OUT"
        return
    fi
    [ "$ev" = "$event" ] || err "hookEventName: got [$ev] want [$event]"
    CTX="$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.additionalContext')"
    for sub in "$@"; do
        case "$CTX" in
            *"$sub"*) ;;
            *) err "additionalContext missing [$sub]: $CTX" ;;
        esac
    done
}

# ---------------------------------------------- user-prompt-router.sh -------
echo "== user-prompt-router.sh =="

begin_case "router: empty stdin -> exit 0, silent"
run "$ROUTER" "" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: no intent match -> exit 0, silent, no query"
run "$ROUTER" "$(pj 'обычный вопрос про погоду' nomatch)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: anti-trigger beats temporal -> silent"
run "$ROUTER" "$(pj 'как сделать дайджест за сегодня' anti)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: intent match but binary missing -> graceful silent skip"
# ACTIVITY_MESH_BIN unset, PATH has no activity-log, fresh HOME has no ~/.local/bin.
run "$ROUTER" "$(pj 'статус по задачам' nobin)"
assert_rc0; assert_silent
end_case

begin_case "router: temporal intent -> --since 24h"
run "$ROUTER" "$(pj 'что было сегодня' temporal)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-temporal"
assert_rc0
assert_argv "query --format text --since 24h --limit 8"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-temporal"
end_case

begin_case "router: status intent -> --kind status --since 48h --limit 10"
run "$ROUTER" "$(pj 'статус по задачам' status)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-status"
assert_rc0
assert_argv "query --format text --kind status --since 48h --limit 10"
assert_emits "UserPromptSubmit" "(status match)" "evt-status"
end_case

begin_case "router: incident intent -> --kind error --since 30d --limit 5"
run "$ROUTER" "$(pj 'что упало вчера' incident)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-incident"
assert_rc0
assert_argv "query --format text --kind error --since 30d --limit 5"
assert_emits "UserPromptSubmit" "(incident match)" "evt-incident"
end_case

begin_case "router: scope intent (scopes-cache) -> --scope billing-proxy"
mkdir -p "$HOMEDIR/.config/activity-mesh"
printf 'billing-proxy\n' > "$HOMEDIR/.config/activity-mesh/scopes-cache"
run "$ROUTER" "$(pj 'billing-proxy deploy logs' scope)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-scope"
assert_rc0
assert_argv "query --format text --scope billing-proxy --since 30d --limit 15"
assert_emits "UserPromptSubmit" "(scope match)" "evt-scope"
end_case

begin_case "router: agent intent -> --agent hermes --limit 10"
run "$ROUTER" "$(pj 'глянь hermes kanban' agent)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-agent"
assert_rc0
assert_argv "query --format text --agent hermes --limit 10"
assert_emits "UserPromptSubmit" "(agent match)" "evt-agent"
end_case

begin_case "router: temporal+agent combo -> --since 24h --agent hermes"
run "$ROUTER" "$(pj 'что делал hermes сегодня' combo)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-combo"
assert_rc0
assert_argv "query --format text --since 24h --limit 8 --agent hermes"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-combo"
end_case

begin_case "router: UPPERCASE Cyrillic prompt -> intents still match (LC_ALL fix)"
run "$ROUTER" "$(pj 'ЧТО ДЕЛАЛ HERMES СЕГОДНЯ' upcyr)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-upcyr"
assert_rc0
assert_argv "query --format text --since 24h --limit 8 --agent hermes"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-upcyr"
end_case

begin_case "router: bare generic 'claude' mention -> NOT an agent intent"
run "$ROUTER" "$(pj 'claude code hooks documentation' bareclaude)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-bare"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: malformed JSON stdin -> exit 0, silent"
run "$ROUTER" 'this is {{ not json' ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: jq absent from PATH -> still emits (absolute /usr/bin/jq)"
run "$ROUTER" "$(pj 'статус по задачам' nojq)" PATH="$MINPATH" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-nojq"
assert_rc0
assert_emits "UserPromptSubmit" "(status match)" "evt-nojq"
end_case

# -------------------------------------------- session-start-digest.sh -------
echo "== session-start-digest.sh =="

begin_case "digest: empty stdin + stub -> SessionStart JSON, both queries exact"
run "$DIGEST" "" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-digest"
assert_rc0
assert_argv "query --since 24h --limit 8 --format text
query --kind error --since 30d --limit 5 --format text"
assert_emits "SessionStart" "recent activity since last session:" "evt-digest" "---"
end_case

begin_case "digest: binary missing -> graceful silent skip"
run "$DIGEST" "$(sj dnobin)"
assert_rc0; assert_silent
end_case

begin_case "digest: stub returns no events -> silent (zero token cost)"
run "$DIGEST" "$(sj dempty)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT=""
assert_rc0; assert_silent
end_case

begin_case "digest: malformed JSON stdin -> exit 0, still emits"
run "$DIGEST" 'garbage {{ not json' ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-mal"
assert_rc0
assert_emits "SessionStart" "evt-mal"
end_case

begin_case "digest: oversized output -> truncation marker, capped context"
BIG="$(/usr/bin/head -c 1500 /dev/zero | /usr/bin/tr '\0' 'x')"
run "$DIGEST" "$(sj dtrunc)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="$BIG"
assert_rc0
assert_emits "SessionStart" "…[truncated]"
# NOTE: the hook's `cut -c 1-1000` truncates PER LINE, not the whole digest, so
# the combined two-query context lands ~2050 chars instead of <=1013. The bound
# below pins "truncation happened at all" (untruncated would be ~3050) while
# still passing if the per-line quirk is ever fixed (~1050).
if [ -n "$CTX" ] && [ "${#CTX}" -ge 2200 ]; then
    err "additionalContext not truncated: ${#CTX} chars"
fi
end_case

begin_case "digest: jq absent from PATH -> still emits (absolute /usr/bin/jq)"
run "$DIGEST" "$(sj dnojq)" PATH="$MINPATH" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-dnojq"
assert_rc0
assert_emits "SessionStart" "evt-dnojq"
end_case

# ---------------------------------------------------------------- summary ---
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
