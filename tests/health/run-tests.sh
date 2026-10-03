#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEALTH="${HEALTH_DIR:-$REPO_ROOT/health}"

JQ="/usr/bin/jq"
if [ ! -x "$JQ" ]; then
    JQ="$(command -v jq)" || { echo "jq is required to run the health suite" >&2; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/activity-mesh-health-tests.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)
HOST=$(hostname)
PASS=0
FAIL=0
CASE_N=0
CASE=""
ERRORS=""
OUT=""
C=""
SYNC=""
STATE=""
STORE=""
LAST_WAKE=0

begin_case() {
    CASE="$1"
    ERRORS=""
    CASE_N=$((CASE_N + 1))
    C="$WORK/case-$CASE_N"
    SYNC="$C/sync"
    STATE="$C/state"
    STORE="$C/store"
    mkdir -p "$C/home" "$SYNC" "$STATE" "$STORE"
    LAST_WAKE=$((NOW - 3 * 86400))
}

err() { ERRORS="${ERRORS}      - $1"$'\n'; }

end_case() {
    if [ -z "$ERRORS" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$CASE"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n%s' "$CASE" "$ERRORS"
    fi
}

gen() {
    "$JQ" -cn --argjson n "$2" --argjson t0 "$3" --argjson step "$4" --arg agent "$5" \
        --arg kind "$6" --arg scope "$7" --arg summary "$8" --arg p "${9:-id}" --arg host "${10:-$HOST}" '
        range(0; $n) as $i
        | {v: 1, id: "\($p)-\($i)", ts: (($t0 + $i * $step) | todate | sub("Z$"; ".123456Z")),
           host: $host, agent: $agent, kind: $kind, scope: $scope, summary: $summary}' >> "$1"
}

stamp() { "$JQ" -rn --argjson t "$1" '$t | strftime("%Y%m%d%H%M.%S")'; }

gotime() { "$JQ" -rn --argjson t "$1" '$t | strftime("%Y/%m/%d %H:%M:%S")'; }

isotime() { "$JQ" -rn --argjson t "$1" '$t | todate'; }

ev_at() {
    "$JQ" -cn --arg id "$2" --arg ts "$3" --arg kind "$4" \
        '{v: 1, id: $id, ts: $ts, host: "h", agent: "cli", kind: $kind, scope: "memory", summary: "x"}' >> "$1"
}

run_check() {
    local name="$1"
    shift
    OUT=$(env HOME="$C/home" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_STATE="$STATE" \
        ACTIVITY_MESH_HOME="$STORE" ACTIVITY_MESH_LAST_WAKE="$LAST_WAKE" \
        OFFLINE_HOSTS_JSON="$C/offline-hosts.json" "$@" \
        bash "$HEALTH/checks/$name.sh" 2>"$C/stderr")
}

expect() {
    if ! printf '%s' "$OUT" | "$JQ" -e "$1" >/dev/null 2>&1; then
        err "$2 (got: ${OUT:-<no output>})"
    fi
}

LOCAL="events-$HOST.jsonl"

begin_case "lib: the last wake time is found under the launchd PATH without an override"
wake=$(env -i HOME="$C/home" PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ACTIVITY_MESH_STATE="$STATE" \
    /bin/bash -c '. "$1/lib.sh" && am_last_wake' am-lib "$HEALTH" 2>"$C/stderr")
case "$wake" in
    ''|*[!0-9]*) err "am_last_wake printed [$wake]" ;;
    *) if [ "$wake" -le 0 ] || [ "$wake" -gt "$(date +%s)" ]; then err "am_last_wake=$wake is outside (0, now]"; fi ;;
esac
end_case

begin_case "lib: the shared ts parser reads Z and offset stamps and gives 0 for everything else"
ref=$("$JQ" -rn '"2026-10-03T19:19:20Z" | fromdateiso8601')
got=$(env -i HOME="$C/home" PATH=/usr/bin:/bin ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_JQ="$JQ" \
    /bin/bash -c '. "$1/lib.sh" && "$AM_JQ" -nc "$AM_JQ_DEFS$2"' am-lib "$HEALTH" \
    '[{ts: "2026-10-03T19:19:20Z"}, {ts: "2026-10-03T19:19:20.123456Z"}, {ts: "2026-10-03T22:19:20+03:00"}, {ts: "2026-10-03T22:19:20.5+0300"}, {ts: "2026-10-03T13:49:20-05:30"}, {ts: 12345}, {ts: null}, {ts: ["x"]}, {}, {ts: "garbage"}, {ts: "2026-10-03T19:19:20+25:00"}, {ts: "2026-10-03T19:19:20"}, 5] | map(ev_ts)' 2>"$C/stderr")
want="[$ref,$ref,$ref,$ref,$ref,0,0,0,0,0,0,0,0]"
[ "$got" = "$want" ] || err "ev_ts gave ${got:-<nothing>}, want $want"
end_case

begin_case "adoption-ratio: heartbeat canaries are self-monitoring, not a writing agent"
gen "$SYNC/$LOCAL" 120 $((NOW - 5 * 86400)) 3600 heartbeat canary activity-mesh "hourly heartbeat ok=1" hb
gen "$SYNC/$LOCAL" 20 $((NOW - 4 * 86400)) 7200 cli note memory "memory entry changed" cli
run_check adoption-ratio
expect '.tier <= 1' "adoption must not page"
expect '(.message | test("heartbeat")) | not' "heartbeat must not be counted as an agent"
expect '.message | test("cli")' "the only real writer should be named"
end_case

begin_case "adoption-ratio: two comparable writers read as balanced"
gen "$SYNC/$LOCAL" 30 $((NOW - 3 * 86400)) 3600 hermes handoff memory "handoff" he
gen "$SYNC/$LOCAL" 25 $((NOW - 3 * 86400)) 3600 cli note memory "note" cl
run_check adoption-ratio
expect '.status == "ok" and .tier == 1' "balanced writers are ok"
end_case

begin_case "canary: a laptop that slept most of the day is not a writer failure"
gen "$SYNC/$LOCAL" 9 $((NOW - 86400 + 600)) 3600 heartbeat canary activity-mesh "hourly heartbeat ok=1" a
gen "$SYNC/$LOCAL" 1 $((NOW - 1500)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" b
LAST_WAKE=$((NOW - 1800))
run_check canary
expect '.tier <= 1' "10 canaries after a long sleep must not page"
end_case

begin_case "canary: awake for hours without a fresh canary is a writer stall"
gen "$SYNC/$LOCAL" 20 $((NOW - 86400 + 60)) 3600 heartbeat canary activity-mesh "hourly heartbeat ok=1" c
LAST_WAKE=$((NOW - 6 * 3600))
run_check canary
expect '.tier >= 3' "no canary for ~4h while awake must fail"
end_case

begin_case "canary: a canary three hours old right after waking is fine, only the wake guard can tell"
gen "$SYNC/$LOCAL" 4 $((NOW - 3 * 3600 - 180)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" g
LAST_WAKE=$((NOW - 1800))
run_check canary
expect '.tier <= 1' "an old canary must not fail while the machine woke less than the stale limit ago"
end_case

begin_case "canary: canary lines with a non-string ts do not blind the check"
gen "$SYNC/$LOCAL" 5 $((NOW - 3600)) 600 heartbeat canary activity-mesh "hourly heartbeat ok=1" n
printf '{"v":1,"id":"bad-num","ts":1791055160,"host":"h","agent":"heartbeat","kind":"canary","scope":"activity-mesh","summary":"hourly heartbeat ok=1"}\n' >> "$SYNC/$LOCAL"
printf '{"v":1,"id":"bad-arr","ts":["2026-10-03T19:19:20Z"],"host":"h","agent":"heartbeat","kind":"canary","scope":"activity-mesh","summary":"hourly heartbeat ok=1"}\n' >> "$SYNC/$LOCAL"
printf '{"v":1,"id":"bad-null","ts":null,"host":"h","agent":"heartbeat","kind":"canary","scope":"activity-mesh","summary":"hourly heartbeat ok=1"}\n' >> "$SYNC/$LOCAL"
run_check canary
expect '.tier == 1 and .status == "ok"' "valid canaries are still seen next to lines with a non-string ts"
end_case

begin_case "hook-health: clock-sync failures in heartbeat.log are not hook errors"
printf '[%s] clock-sync failed (offset cache stale)\n' "$(isotime $((NOW - 600)))" > "$STATE/heartbeat.log"
printf '[%s] emitted intent=temporal session=s chars=10 fire_tokens=2 budget=2\n' "$(isotime $((NOW - 300)))" > "$STATE/user-prompt-router.log"
run_check hook-health
expect '.tier <= 1' "heartbeat.log lines must not count"
end_case

begin_case "hook-health: a hook that lost its binary two hours ago is reported"
printf '[%s] skip intent=temporal: no binary\n' "$(isotime $((NOW - 7200)))" > "$STATE/user-prompt-router.log"
printf '[%s] skip session=x: activity-log binary not found\n' "$(isotime $((NOW - 3 * 86400)))" > "$STATE/session-start.log"
run_check hook-health
expect '.tier == 2' "one hook error inside the 6h window warns"
end_case

begin_case "ingester-error: watcher emit failures are lost events and are reported"
for i in 1 2 3 4; do
    printf '%s emit error src="memory-entry" path="/x/%d.md": activity-log emit failed (signal: killed): \n' "$(gotime $((NOW - 600 * i)))" "$i" >> "$STATE/watcher.err"
done
printf '%s emit queue full src="memory-entry": 3 events lost\n' "$(gotime $((NOW - 300)))" >> "$STATE/watcher.err"
printf '%s ingested 1 events from %s\n' "$(gotime $((NOW - 60)))" "$LOCAL" > "$STATE/daemon.err"
run_check ingester-error
expect '.tier >= 2' "lost watcher events in the window must warn"
expect '.message | test("7 watcher events lost")' "emit errors and rollup drops are summed in the message"
end_case

begin_case "ingester-error: a clean daemon log is a real ok, not 'no ingest.log yet'"
printf '%s ingested 1 events from %s\n' "$(gotime $((NOW - 60)))" "$LOCAL" > "$STATE/daemon.err"
run_check ingester-error
expect '.status == "ok" and .tier == 1' "a scanned clean log is tier 1 ok"
end_case

begin_case "redactor-coverage: PII deep in a long shard is found"
gen "$SYNC/$LOCAL" 9000 $((NOW - 20 * 86400)) 60 cli note memory "plain" p
gen "$SYNC/$LOCAL" 1 $((NOW - 3600)) 60 cli note memory "mail me at someone@example.com" q
gen "$SYNC/$LOCAL" 999 $((NOW - 3000)) 1 cli note memory "plain" r
run_check redactor-coverage
expect '.tier >= 2' "an email in a recent event must be reported"
end_case

begin_case "redactor-coverage: clean shards read as ok and report how many lines were scanned"
gen "$SYNC/$LOCAL" 50 $((NOW - 7200)) 60 cli note memory "plain note" ok
run_check redactor-coverage
expect '.tier == 1 and .status == "ok" and (.message | test("^0 hits in 50 lines"))' "no PII means ok with the scanned line count"
end_case

begin_case "secrets-bypass: a secret written two hours ago is still a critical leak"
SECRET="AKIA$(printf 'Q%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)"
gen "$SYNC/$LOCAL" 1 $((NOW - 7200)) 60 cli note memory "key $SECRET" s
run_check secrets-bypass
expect '.tier == 4 and .status == "critical"' "a leak older than 30 minutes must be found"
end_case

begin_case "secrets-bypass: clean shards read as ok"
gen "$SYNC/$LOCAL" 50 $((NOW - 7200)) 60 cli note memory "plain note" ok
run_check secrets-bypass
expect '.tier == 1 and .status == "ok"' "no secrets means ok"
end_case

begin_case "silence: right after wake, a stale remote shard is not judged yet"
gen "$SYNC/events-otherhost.jsonl" 1 $((NOW - 13 * 3600)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" o otherhost
TZ=UTC touch -t "$(stamp $((NOW - 13 * 3600)))" "$SYNC/events-otherhost.jsonl"
LAST_WAKE=$((NOW - 300))
run_check silence
expect '.tier <= 1' "five minutes after wake Syncthing has not caught up yet"
end_case

begin_case "silence: a remote host silent for 13h while we were awake fails"
gen "$SYNC/events-otherhost.jsonl" 1 $((NOW - 13 * 3600)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" o otherhost
TZ=UTC touch -t "$(stamp $((NOW - 13 * 3600)))" "$SYNC/events-otherhost.jsonl"
LAST_WAKE=$((NOW - 3 * 3600))
run_check silence
expect '.tier == 3' "13h of silence after 3h awake is a failure"
end_case

begin_case "silence: an owner-disabled host stays quiet"
gen "$SYNC/events-otherhost.jsonl" 1 $((NOW - 30 * 3600)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" o otherhost
TZ=UTC touch -t "$(stamp $((NOW - 30 * 3600)))" "$SYNC/events-otherhost.jsonl"
printf '{"otherhost": {"since": "2026-10-01"}}\n' > "$C/offline-hosts.json"
run_check silence
expect '.tier == 1 and (.message | test("otherhost"))' "offline host is listed at tier 1"
end_case

begin_case "sync-lag: changes delivered right after wake are not lag"
gen "$SYNC/events-otherhost.jsonl" 1 $((NOW - 7200)) 60 heartbeat canary activity-mesh "hourly heartbeat ok=1" l otherhost
TZ=UTC touch -t "$(stamp $((NOW - 7200)))" "$SYNC/events-otherhost.jsonl"
LAST_WAKE=$((NOW - 30))
run_check sync-lag
expect '.tier <= 1' "lag is measured from wake, not from the remote append"
end_case

begin_case "schema-drift: namespaced org/name kinds are allowed, as emit allows them"
printf 'kinds:\n  - name: note\n' > "$SYNC/kinds.yaml"
printf 'scopes:\n  - name: memory\n' > "$SYNC/scopes.yaml"
gen "$SYNC/$LOCAL" 3 $((NOW - 3600)) 60 cli acme/thing memory "ext kind" k
run_check schema-drift
expect '.tier <= 1' "acme/thing is a valid extension kind"
end_case

begin_case "schema-drift: an unregistered plain kind is drift"
printf 'kinds:\n  - name: note\n' > "$SYNC/kinds.yaml"
printf 'scopes:\n  - name: memory\n' > "$SYNC/scopes.yaml"
gen "$SYNC/$LOCAL" 2 $((NOW - 3600)) 60 cli bogus memory "bad kind" b
run_check schema-drift
expect '.tier == 2' "two unknown kinds warn"
end_case

begin_case "schema-drift: a +03:00 timestamp is converted to UTC before the 24h window is applied"
printf 'kinds:\n  - name: note\n' > "$SYNC/kinds.yaml"
printf 'scopes:\n  - name: memory\n' > "$SYNC/scopes.yaml"
t_in=$(isotime $((NOW - 3600 + 10800)))
t_out=$(isotime $((NOW - 90000 + 10800)))
ev_at "$SYNC/$LOCAL" off-in "${t_in%Z}+03:00" zzz
ev_at "$SYNC/$LOCAL" off-out "${t_out%Z}+03:00" zzz
run_check schema-drift
expect '.tier == 2 and (.message | test("^1 unknown values"))' "only the event that is one hour old in UTC counts, the one 25h old does not"
end_case

begin_case "ulid-collision: a duplicate far apart in the shard is found"
gen "$SYNC/$LOCAL" 1 $((NOW - 10 * 86400)) 60 cli note memory "first" dup
gen "$SYNC/$LOCAL" 2500 $((NOW - 9 * 86400)) 60 cli note memory "filler" f
gen "$SYNC/$LOCAL" 1 $((NOW - 60)) 60 cli note memory "second" dup
run_check ulid-collision
expect '.tier == 4' "the duplicate ULID must be critical"
end_case

begin_case "master: a hung check is cut off and reported, the run still completes"
mkdir -p "$C/h/checks"
cp "$HEALTH/master.sh" "$HEALTH/lib.sh" "$C/h/"
printf '%s\n' '. "$(dirname "$0")/../lib.sh"' 'am_start' 'sleep 60' 'am_emit hung 1 ok late' > "$C/h/checks/hung.sh"
printf '%s\n' '. "$(dirname "$0")/../lib.sh"' 'am_start' 'am_emit quick 1 ok fine' > "$C/h/checks/quick.sh"
t0=$(date +%s)
OUT=$(env HOME="$C/home" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_HOME="$STORE" \
    ACTIVITY_MESH_CHECK_TIMEOUT_S=2 bash "$C/h/master.sh" --dry-run 2>"$C/stderr")
t1=$(date +%s)
expect '.checks | map(select(.name == "hung"))[0].message | test("timed out")' "the hung check is reported as timed out"
expect '.checks | map(select(.name == "quick"))[0].status == "ok"' "the quick check still reports"
[ $((t1 - t0)) -lt 20 ] || err "master took $((t1 - t0))s with a 2s check timeout"
end_case

begin_case "master: an empty checks dir does not crash bash 3.2 under set -u"
mkdir -p "$C/h/checks"
cp "$HEALTH/master.sh" "$HEALTH/lib.sh" "$C/h/"
OUT=$(env HOME="$C/home" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_HOME="$STORE" \
    bash "$C/h/master.sh" --dry-run 2>"$C/stderr")
expect '.checks == [] and .summary.max_tier == 0' "an empty run still produces a snapshot"
if grep -q 'unbound variable' "$C/stderr"; then err "stderr: $(cat "$C/stderr")"; fi
end_case

begin_case "master: the same alert is not repeated every run, a new one goes out at once"
mkdir -p "$C/h/checks"
cp "$HEALTH/master.sh" "$HEALTH/lib.sh" "$C/h/"
printf '%s\n' '. "$(dirname "$0")/../lib.sh"' 'am_start' 'am_emit flaky 2 warn "something off"' > "$C/h/checks/flaky.sh"
run_master() {
    env HOME="$C/home" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_HOME="$STORE" \
        ACTIVITY_MESH_NOTIFY_CMD="tee -a $C/notified" bash "$C/h/master.sh" >/dev/null 2>&1
}
run_master
run_master
sent=$(grep -c 'flaky=warn' "$C/notified" 2>/dev/null || echo 0)
[ "$sent" = 1 ] || err "same alert sent $sent times in two runs, want 1"
printf '%s\n' '. "$(dirname "$0")/../lib.sh"' 'am_start' 'am_emit other 3 fail "new problem"' > "$C/h/checks/other.sh"
run_master
grep -q 'other=fail' "$C/notified" 2>/dev/null || err "a new failing check was not alerted"
[ "$(wc -l < "$STATE/alerts.log" 2>/dev/null | tr -d ' ')" = 2 ] || err "alerts.log should record the 2 alerts that went out"
end_case

begin_case "weekly-digest: alerts are counted, load timeouts are not daemon failures, budget is per fire"
gen "$SYNC/$LOCAL" 100 $((NOW - 6 * 86400)) 3600 heartbeat canary activity-mesh "hourly heartbeat ok=1" w1
gen "$SYNC/$LOCAL" 50 $((NOW - 2 * 86400)) 1800 heartbeat canary activity-mesh "hourly heartbeat ok=0 why=timeout busy=1" w2
gen "$SYNC/$LOCAL" 5 $((NOW - 86400)) 3600 heartbeat canary activity-mesh "hourly heartbeat ok=0 why=connect-refused" w3
{
    printf '%s master warn\n' "$(isotime $((NOW - 3600)))"
    printf '%s master fail\n' "$(isotime $((NOW - 7200)))"
    printf '%s heartbeat fail\n' "$(isotime $((NOW - 86400)))"
    printf '%s master warn\n' "$(isotime $((NOW - 9 * 86400)))"
} > "$STATE/alerts.log"
printf '%s s1 400\n%s s1 300\n%s s2 100\n' "$(isotime $((NOW - 3600)))" "$(isotime $((NOW - 3500)))" "$(isotime $((NOW - 3400)))" > "$STATE/injections.log"
OUT=$(env HOME="$C/home" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_HOME="$STORE" \
    bash "$HEALTH/weekly-digest.sh" --dry-run 2>"$C/stderr")
printf '%s' "$OUT" | grep -q 'алертов: 3' || err "expected 3 alerts in the last 7 days: $OUT"
printf '%s' "$OUT" | grep -q 'canary: 5/155' || err "only the 5 conclusive failures out of 155 canaries count: $OUT"
printf '%s' "$OUT" | grep -q 'самолечений' && err "self-heal count has no producer and must go: $OUT"
printf '%s' "$OUT" | grep -qE '/2000|/500 за' || err "token budget must be per fire and per session: $OUT"
end_case

begin_case "heartbeat: the alert is plain text in one language"
mkdir -p "$C/bin"
printf '#!/bin/bash\nexit 0\n' > "$C/bin/activity-log"
chmod +x "$C/bin/activity-log"
env HOME="$C/home" ACTIVITY_MESH_STATE="$STATE" ACTIVITY_MESH_SYNC="$SYNC" ACTIVITY_MESH_BIN="$C/bin/activity-log" \
    ACTIVITY_MESH_HEALTH_URL="http://127.0.0.1:9/health" HEARTBEAT_THRESHOLD=1 CANARY_TIMEOUT=2 \
    ACTIVITY_MESH_NOTIFY_CMD="tee $C/alert.txt" bash "$HEALTH/dead-man-heartbeat.sh" >/dev/null 2>&1
if [ ! -s "$C/alert.txt" ]; then
    err "no alert was produced"
else
    grep -q '[`*━]' "$C/alert.txt" && err "markdown or separator in a plain-text alert: $(cat "$C/alert.txt")"
    grep -q 'Daemon not responding' "$C/alert.txt" && err "English copy glued into the Russian alert"
    grep -q 'Демон' "$C/alert.txt" || err "Russian alert expected by default"
fi
end_case

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
