#!/bin/bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$HERE" ] || [ ! -r "$HERE/lib.sh" ]; then
    printf 'weekly-digest.sh: cannot locate lib.sh (HERE=%s)\n' "$HERE" >&2
    exit 1
fi
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

SYNC="$ACTIVITY_MESH_SYNC"
STATE="$ACTIVITY_MESH_STATE"
CANARY_FAIL_PCT_MAX=${CANARY_FAIL_PCT_MAX:-10}

now=$(date +%s); week_ago=$(( now - 7*86400 )); prev_week_ago=$(( now - 14*86400 ))
week_iso=$("$AM_JQ" -rn --argjson t "$week_ago" '$t | todate')
iso_week=$(date -u +'%G-W%V' 2>/dev/null || echo unknown)
offline_hosts="$(am_offline_hosts)"

hosts=""
for f in "$SYNC"/events-*.jsonl; do
    [ -f "$f" ] || continue
    h=${f##*/}; h=${h%.jsonl}; hosts="$hosts ${h#events-}"
done

stats=$(for h in $hosts; do awk -v h="$h" '{ print h "\t" $0 }' "$SYNC/events-$h.jsonl" 2>/dev/null; done \
    | "$AM_JQ" -nR --argjson week "$week_ago" --argjson prev "$prev_week_ago" \
        --arg hosts "$hosts" --arg off "$offline_hosts" "$AM_JQ_DEFS"'
    def top3(f): group_by(f) | map({k: (.[0] | f), n: length}) | sort_by(-.n) | .[:3];
    ($off | split(" ") | map(select(length > 0))) as $offl
    | [inputs | index("\t") as $i | {h: .[:$i], e: (.[$i + 1:] | fromjson? // null)}
       | select(.e | type == "object") | .e + {_h: .h, _t: (.e | ev_ts)}] as $all
    | ($all | map(select(._t >= $week))) as $w
    | ($w | map(select(.kind == "canary")
               | select(._h | ascii_downcase as $hl | $offl | any(. as $o | $hl | contains($o)) | not))) as $c
    | {events: ($w | length),
       prev: ($all | map(select(._t >= $prev and ._t < $week)) | length),
       self: ($w | map(select(.scope == "activity-mesh")) | length),
       scopes: ($w | top3(.scope // "?")),
       agents: ($w | top3(.agent // "?")),
       hosts: ($hosts | split(" ") | map(select(length > 0)) | map(. as $h | {k: $h, n: ($w | map(select(._h == $h)) | length)})),
       canary_total: ($c | length),
       canary_bad: ($c | map(select((.summary // "") | test("ok=0") and (test("busy=1") | not))) | length),
       canary_busy: ($c | map(select((.summary // "") | test("ok=0") and test("busy=1"))) | length)}')
[ -n "$stats" ] || stats='{"events":0,"prev":0,"self":0,"scopes":[],"agents":[],"hosts":[],"canary_total":0,"canary_bad":0,"canary_busy":0}'

read -r events_now events_prev events_self canary_total canary_bad canary_busy <<< "$(printf '%s' "$stats" | "$AM_JQ" -r \
    '"\(.events) \(.prev) \(.self) \(.canary_total) \(.canary_bad) \(.canary_busy)"')"
top_scopes=$(printf '%s' "$stats" | "$AM_JQ" -r '.scopes | map("\(.k) (\(.n))") | join(", ")')
top_agents=$(printf '%s' "$stats" | "$AM_JQ" -r '.agents | map("\(.k) (\(.n))") | join(", ")')
host_lines=$(printf '%s' "$stats" | "$AM_JQ" -r '.hosts[] | "  • \(.k): \(.n)"')
events_useful=$(( events_now - events_self ))

canary_bad_pct=0
[ "$canary_total" -gt 0 ] && canary_bad_pct=$(( canary_bad * 100 / canary_total ))
if [ "$canary_total" -eq 0 ]; then
    canary_line=$(am_t "canary: no samples, could not check" "canary: замеров нет — проверить не удалось")
else
    canary_line=$(am_t "canary: ${canary_bad}/${canary_total} without an answer (${canary_bad_pct}%, limit ${CANARY_FAIL_PCT_MAX}%)" \
        "canary: ${canary_bad}/${canary_total} без ответа (${canary_bad_pct}%, порог ${CANARY_FAIL_PCT_MAX}%)")
    if [ "$canary_busy" -gt 0 ]; then
        canary_line="$canary_line$(am_t ", $canary_busy more timed out under load (not counted)" \
            ", ещё $canary_busy — таймаут под нагрузкой, не считаю")"
    fi
fi

if [ "$events_prev" -gt 0 ]; then
    pct=$(( (events_now - events_prev) * 100 / events_prev ))
    [ "$pct" -ge 0 ] && pct="+$pct"
    trend="(${pct}% $(am_t "vs last week" "к прошлой неделе"))"
else
    trend="($(am_t "no baseline" "нет базы для сравнения"))"
fi

alerts_count=0
if [ -f "$STATE/alerts.log" ]; then
    alerts_count=$(awk -v c="$week_iso" '$1 >= c { n++ } END { print n + 0 }' "$STATE/alerts.log" 2>/dev/null)
fi

inj="0 0 0"
if [ -f "$STATE/injections.log" ]; then
    inj=$(awk -v c="$week_iso" '
        $1 >= c && $3 ~ /^[0-9]+$/ { n++; s += $3; per[$2] += $3 }
        END { m = 0; for (k in per) if (per[k] > m) m = per[k]; printf "%d %d %d\n", n, (n ? s / n : 0), m }' \
        "$STATE/injections.log" 2>/dev/null)
fi
read -r inj_n inj_avg inj_max_session <<< "${inj:-0 0 0}"
budget_line=$(am_t "token budget: $inj_n injections, avg ${inj_avg}/500 per fire, max ${inj_max_session}/2000 per session" \
    "бюджет токенов: инжектов $inj_n, в среднем ${inj_avg}/500 за инжект, максимум ${inj_max_session}/2000 за сессию")

verdict="OK"
if [ -f "$STATE/last-health.json" ]; then
    case "$("$AM_JQ" -r '.summary.max_tier // 0' "$STATE/last-health.json" 2>/dev/null)" in
        3) verdict="DEGRADED" ;;
        4) verdict="CRITICAL" ;;
    esac
fi
if [ "$canary_total" -gt 0 ] && [ "$canary_bad_pct" -gt "$CANARY_FAIL_PCT_MAX" ] && [ "$verdict" = "OK" ]; then
    verdict="DEGRADED"
    canary_line="$canary_line$(am_t " — status lowered to DEGRADED" " — статус снижен до DEGRADED")"
fi
case "$verdict" in
    CRITICAL) verdict_emoji="🚨"; verdict_label=$(am_t "CRITICAL" "КРИТИЧНО"); severity=fail ;;
    DEGRADED) verdict_emoji="⚠️"; verdict_label=$(am_t "ATTENTION" "ВНИМАНИЕ"); severity=warn ;;
    *)        verdict_emoji="✅"; verdict_label="OK"; severity=ok ;;
esac

case "$ACTIVITY_MESH_LANG" in
    en*) DIGEST="📊 activity-mesh weekly digest · ${verdict_emoji} ${verdict_label}

Week ${iso_week}, status: ${verdict}.

• events: ${events_now} ${trend}
• self-monitoring among them: ${events_self} (useful: ${events_useful})
• ${canary_line}
• scopes: ${top_scopes:-none}
• agents: ${top_agents:-none}
• alerts: ${alerts_count}
• ${budget_line}

by host:
${host_lines}

⚡ Action: automatic — keep watching (silence ≠ OK)" ;;
    *) DIGEST="📊 Недельный дайджест activity-mesh · ${verdict_emoji} ${verdict_label}

Неделя ${iso_week}, статус: ${verdict}.

• событий: ${events_now} ${trend}
• из них самонаблюдение: ${events_self} (полезных: ${events_useful})
• ${canary_line}
• темы: ${top_scopes:-нет}
• агенты: ${top_agents:-нет}
• алертов: ${alerts_count}
• ${budget_line}

по хостам:
${host_lines}

⚡ Действие: автоматически — следить (тишина ≠ OK)" ;;
esac

printf '%s\n' "$DIGEST"

mkdir -p "$STATE" 2>/dev/null || true
printf '%s\n' "$DIGEST" > "$STATE/last-weekly-digest.md" 2>/dev/null || true
printf '{"generated_at":%d,"window":"%s","events":%d,"events_self":%d,"canary_total":%d,"canary_bad":%d,"canary_busy":%d,"canary_bad_pct":%d,"verdict":"%s"}\n' \
    "$now" "$iso_week" "$events_now" "$events_self" \
    "$canary_total" "$canary_bad" "$canary_busy" "$canary_bad_pct" "$verdict" \
    > "$STATE/last-digest.json" 2>/dev/null || true

[ "$DRY_RUN" -eq 1 ] && exit 0

am_notify "$DIGEST" "$severity" || printf 'warn: weekly digest undeliverable\n' >&2

exit 0
