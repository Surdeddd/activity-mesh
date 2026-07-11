#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$REPO_ROOT/hooks/user-prompt-router.sh"
DIGEST="$REPO_ROOT/hooks/session-start-digest.sh"

JQ="/usr/bin/jq"
if [ ! -x "$JQ" ]; then
    JQ="$(command -v jq)" || { echo "jq is required to run assertions" >&2; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/activity-mesh-hook-tests.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

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
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] && ln -s "$PY3" "$FULLPATH/python3"

STUB="$WORK/activity-log"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_ARGV:?}"
if [ -n "${STUB_OUTPUT:-}" ]; then printf '%s\n' "$STUB_OUTPUT"; fi
exit 0
EOF
chmod +x "$STUB"

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

seed_agents_cache() {
    mkdir -p "$HOMEDIR/.config/activity-mesh"
    printf 'hermes\thermes,хермес,гермес\t\nviktor\tviktor,виктор\t\nanton\tanton,антон\t\nclaude-mac\tclaude-mac,клод-mac,клод-мак\tclaude,клод\n' \
        > "$HOMEDIR/.config/activity-mesh/agents-cache"
}

err() { ERRORS="${ERRORS}      - $1"$'\n'; }

end_case() {
    if [ -z "$ERRORS" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$CASE"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n%s' "$CASE" "$ERRORS"
    fi
}

run() {
    local hook="$1" stdin="$2"
    shift 2
    printf '%s' "$stdin" | env -i HOME="$HOMEDIR" PATH="$FULLPATH" STUB_ARGV="$ARGV_FILE" "$@" \
        /bin/bash "$hook" > "$HOMEDIR/stdout" 2> "$HOMEDIR/stderr"
    RC=$?
    OUT="$(cat "$HOMEDIR/stdout")"
}

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

begin_case "router: agent intent (agents-cache) -> --agent hermes --limit 10"
seed_agents_cache
run "$ROUTER" "$(pj 'глянь hermes kanban' agent)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-agent"
assert_rc0
assert_argv "query --format text --agent hermes --limit 10"
assert_emits "UserPromptSubmit" "(agent match)" "evt-agent"
end_case

begin_case "router: Cyrillic agent alias 'антон' -> --agent anton"
seed_agents_cache
run "$ROUTER" "$(pj 'глянь что антон наделал в проде' cyragent)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-anton"
assert_rc0
assert_argv "query --format text --agent anton --limit 10"
assert_emits "UserPromptSubmit" "(agent match)" "evt-anton"
end_case

begin_case "router: temporal+agent combo -> --since 24h --agent hermes"
seed_agents_cache
run "$ROUTER" "$(pj 'что делал hermes сегодня' combo)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-combo"
assert_rc0
assert_argv "query --format text --since 24h --limit 8 --agent hermes"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-combo"
end_case

begin_case "router: UPPERCASE Cyrillic prompt -> intents still match (LC_ALL fix)"
seed_agents_cache
run "$ROUTER" "$(pj 'ЧТО ДЕЛАЛ HERMES СЕГОДНЯ' upcyr)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-upcyr"
assert_rc0
assert_argv "query --format text --since 24h --limit 8 --agent hermes"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-upcyr"
end_case

begin_case "router: bare generic 'claude' (weak alias) -> NOT an agent intent"
seed_agents_cache
run "$ROUTER" "$(pj 'claude code hooks documentation' bareclaude)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-bare"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: weak alias qualifies an existing intent -> --agent claude-mac"
seed_agents_cache
run "$ROUTER" "$(pj 'что клод делал сегодня' weakqual)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-weak"
assert_rc0
assert_argv "query --format text --since 24h --limit 8 --agent claude-mac"
assert_emits "UserPromptSubmit" "(temporal match)" "evt-weak"
end_case

begin_case "router: agents-cache absent -> agent mention alone stays silent"
run "$ROUTER" "$(pj 'глянь hermes kanban' nocache)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: session over 2000-token hard cap -> silent, no query"
mkdir -p "$HOMEDIR/.local/state/activity-mesh"
printf '5000\n' > "$HOMEDIR/.local/state/activity-mesh/tokens-hooktest-$$-capped"
run "$ROUTER" "$(pj 'статус по задачам' capped)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-cap"
assert_rc0; assert_silent; assert_stub_not_called
end_case

begin_case "router: emitted injection appends per-fire telemetry line"
run "$ROUTER" "$(pj 'статус по задачам' telem)" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-telem"
assert_rc0
assert_emits "UserPromptSubmit" "evt-telem"
INJ="$HOMEDIR/.local/state/activity-mesh/injections.log"
if [ ! -s "$INJ" ]; then
    err "injections.log missing or empty"
else
    line="$(tail -1 "$INJ")"
    case "$line" in
        *"hooktest-$$-telem"*) ;;
        *) err "injections.log line lacks session id: $line" ;;
    esac
    fire=$(printf '%s' "$line" | awk '{print $3}')
    case "$fire" in
        ''|*[!0-9]*) err "injections.log third field not a token count: $line" ;;
    esac
fi
CUM="$HOMEDIR/.local/state/activity-mesh/tokens-hooktest-$$-telem"
[ -s "$CUM" ] || err "cumulative tokens file missing"
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

echo "== session-start-digest.sh =="

begin_case "digest: empty stdin + stub -> SessionStart JSON, both queries exact"
run "$DIGEST" "" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-digest"
assert_rc0
assert_argv "query --since 24h --exclude-kind canary,heartbeat --limit 8 --format text
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
if [ -n "$CTX" ] && [ "${#CTX}" -ge 2200 ]; then
    err "additionalContext not truncated: ${#CTX} chars"
fi
end_case

begin_case "digest: jq absent from PATH -> still emits (absolute /usr/bin/jq)"
run "$DIGEST" "$(sj dnojq)" PATH="$MINPATH" ACTIVITY_MESH_BIN="$STUB" STUB_OUTPUT="evt-dnojq"
assert_rc0
assert_emits "SessionStart" "evt-dnojq"
end_case

echo "== secret-redactor.sh =="
REDACTOR="$REPO_ROOT/hooks/secret-redactor.sh"

begin_case "redactor: binary missing, default mode -> FAIL-CLOSED (exit 1, no output)"
printf 'sensitive text' | env -i HOME="$HOMEDIR" PATH="$MINPATH" \
    /bin/bash "$REDACTOR" > "$HOMEDIR/stdout" 2> "$HOMEDIR/stderr"
RC=$?
OUT="$(cat "$HOMEDIR/stdout")"
[ "$RC" -eq 1 ] || err "expected exit 1 (fail-closed), got $RC"
[ -z "$OUT" ] || err "fail-closed must emit NOTHING, got: $OUT"
end_case

begin_case "redactor: binary missing, ACTIVITY_MESH_REDACTOR_MODE=open -> passthrough"
printf 'sensitive text' | env -i HOME="$HOMEDIR" PATH="$MINPATH" ACTIVITY_MESH_REDACTOR_MODE=open \
    /bin/bash "$REDACTOR" > "$HOMEDIR/stdout" 2> "$HOMEDIR/stderr"
RC=$?
OUT="$(cat "$HOMEDIR/stdout")"
[ "$RC" -eq 0 ] || err "fail-open must exit 0, got $RC"
[ "$OUT" = "sensitive text" ] || err "fail-open must pass text through, got: $OUT"
grep -q "UNREDACTED" "$HOMEDIR/stderr" || err "fail-open must warn loudly on stderr"
end_case

begin_case "redactor: binary present -> shells out to redact --stdin"
printf 'some text' | env -i HOME="$HOMEDIR" PATH="$MINPATH" \
    ACTIVITY_MESH_BIN="$STUB" STUB_ARGV="$ARGV_FILE" STUB_OUTPUT="redacted-out" \
    /bin/bash "$REDACTOR" > "$HOMEDIR/stdout" 2> "$HOMEDIR/stderr"
RC=$?
OUT="$(cat "$HOMEDIR/stdout")"
[ "$RC" -eq 0 ] || err "expected exit 0, got $RC"
assert_argv "redact --stdin"
[ "$OUT" = "redacted-out" ] || err "expected stub output, got: $OUT"
end_case

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
