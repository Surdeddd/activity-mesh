#!/bin/bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

SYNC="$ACTIVITY_MESH_SYNC"
STATE="$ACTIVITY_MESH_STATE"

now=$(date +%s); week_ago=$(( now - 7*86400 ))
prev_week_ago=$(( now - 14*86400 ))
iso_week=$(date -u +'%G-W%V' 2>/dev/null || echo unknown)

TMP_SCOPES=$(mktemp); TMP_AGENTS=$(mktemp); TMP_HOSTS=$(mktemp)
trap 'rm -f "$TMP_SCOPES" "$TMP_AGENTS" "$TMP_HOSTS"' EXIT

events_now=0; events_prev=0

if [ -d "$SYNC" ]; then
    for f in "$SYNC"/events-*.jsonl; do
        [ -f "$f" ] || continue
        host=$(basename "$f" .jsonl); host=${host#events-}
        host_n=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            ts=$(printf '%s' "$line" | /usr/bin/jq -r '.ts // empty' 2>/dev/null)
            ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
                      || date -u -d "$ts" +%s 2>/dev/null || echo 0)
            if [ "$ts_epoch" -ge "$week_ago" ]; then
                events_now=$((events_now+1)); host_n=$((host_n+1))
                printf '%s\n' "$line" | /usr/bin/jq -r '.scope // "?"' 2>/dev/null >> "$TMP_SCOPES"
                printf '%s\n' "$line" | /usr/bin/jq -r '.agent // "?"' 2>/dev/null >> "$TMP_AGENTS"
            elif [ "$ts_epoch" -ge "$prev_week_ago" ] && [ "$ts_epoch" -lt "$week_ago" ]; then
                events_prev=$((events_prev+1))
            fi
        done < <(tail -n 5000 "$f" 2>/dev/null)
        printf '%s %d\n' "$host" "$host_n" >> "$TMP_HOSTS"
    done
fi

if [ "$events_prev" -gt 0 ]; then
    pct=$(( (events_now - events_prev) * 100 / events_prev ))
    if [ "$pct" -ge 0 ]; then trend="(+${pct}% vs last week)"; else trend="(${pct}% vs last week)"; fi
else
    trend="(no baseline)"
fi

top_scopes=""
while read -r n s; do
    [ -z "$s" ] && continue
    top_scopes="${top_scopes}${s} (${n}), "
done < <(/usr/bin/sort "$TMP_SCOPES" | /usr/bin/uniq -c | /usr/bin/sort -nr | head -3 | awk '{n=$1; $1=""; sub(/^ /,""); print n, $0}')
top_scopes="${top_scopes%, }"

top_agents=""
while read -r n a; do
    [ -z "$a" ] && continue
    top_agents="${top_agents}${a} (${n}), "
done < <(/usr/bin/sort "$TMP_AGENTS" | /usr/bin/uniq -c | /usr/bin/sort -nr | head -3 | awk '{n=$1; $1=""; sub(/^ /,""); print n, $0}')
top_agents="${top_agents%, }"

host_lines=""
while read -r host n; do
    [ -z "$host" ] && continue
    host_lines="${host_lines}  • ${host}: ${n}"$'\n'
done < "$TMP_HOSTS"

ALERT_LOG="$STATE/alerts.log"; HEAL_LOG="$STATE/self-heal.log"
alerts_count=0; heals_count=0
[ -f "$ALERT_LOG" ] && alerts_count=$(/usr/bin/wc -l < "$ALERT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
[ -f "$HEAL_LOG" ]  && heals_count=$(/usr/bin/wc -l < "$HEAL_LOG"  2>/dev/null | tr -d ' ' || echo 0)

tb_avg=0; tb_n=0
shopt -s nullglob
for f in /tmp/activity-tokens-*; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) continue ;; esac
    tb_avg=$(( tb_avg + v )); tb_n=$(( tb_n + 1 ))
done
shopt -u nullglob
[ "$tb_n" -gt 0 ] && tb_avg=$(( tb_avg / tb_n )) || tb_avg=0
tb_pct=$(( tb_avg * 100 / 500 ))

verdict="OK"
verdict_emoji="✅"
verdict_level_en="OK"
verdict_level_ru="OK"
if [ -f "$STATE/last-health.json" ]; then
    mt=$(/usr/bin/jq -r '.summary.max_tier // 0' "$STATE/last-health.json" 2>/dev/null)
    case "$mt" in
        3) verdict="DEGRADED"; verdict_emoji="⚠️"; verdict_level_en="WARN"; verdict_level_ru="ВНИМАНИЕ" ;;
        4) verdict="CRITICAL"; verdict_emoji="🚨"; verdict_level_en="CRITICAL"; verdict_level_ru="КРИТИЧНО" ;;
        *) verdict="OK"; verdict_emoji="✅"; verdict_level_en="OK"; verdict_level_ru="OK" ;;
    esac
fi

ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host_short=$(hostname -s 2>/dev/null || echo "?")

DIGEST=$(cat <<EOF
📊 *Activity-mesh weekly digest / Недельный дайджест Activity-mesh* · ${verdict_emoji} ${verdict_level_en} / ${verdict_level_ru}

Week ${iso_week}. Status: **${verdict}**.

📊 Details:
• events captured: ${events_now} ${trend}
• top scopes: ${top_scopes:-none}
• top agents: ${top_agents:-none}
• alerts fired: ${alerts_count}
• self-heals: ${heals_count}
• token budget avg: ${tb_avg}/500 ambient (${tb_pct}% of cap)

per-host counts:
${host_lines}
⚡ Action: automatic — keep watching (silence ≠ OK)

━━━━━━━━━━━━━━━━━

🇷🇺 Неделя ${iso_week}. Status: **${verdict}**.

📊 Детали:
• events captured: ${events_now} ${trend}
• top scopes: ${top_scopes:-none}
• top agents: ${top_agents:-none}
• alerts fired: ${alerts_count}
• self-heals: ${heals_count}
• token budget avg: ${tb_avg}/500 ambient (${tb_pct}% от cap)

per-host counts:
${host_lines}
⚡ Действие: автоматически — следить (silence ≠ OK)

\`${ts_iso} · ${host_short}\`
EOF
)

printf '%s\n' "$DIGEST"

mkdir -p "$STATE" 2>/dev/null || true
printf '%s\n' "$DIGEST" > "$STATE/last-weekly-digest.md" 2>/dev/null || true
printf '{"generated_at":%d,"window":"%s","events":%d,"verdict":"%s"}\n' \
    "$now" "$iso_week" "$events_now" "$verdict" \
    > "$STATE/last-digest.json" 2>/dev/null || true

[ "$DRY_RUN" -eq 1 ] && exit 0

am_notify "$DIGEST" || printf 'warn: weekly digest undeliverable\n' >&2

exit 0
