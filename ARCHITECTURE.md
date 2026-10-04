# activity-mesh — Architecture v1

## Core principles

1. **Per-host shards** — each machine writes to `events-<host>.jsonl`. Single writer per file = zero Syncthing conflicts ever.
2. **Universal CLI is primary contract** — any agent/SDK works via shell-out. MCP/skills are optimizations on top.
3. **Local-first reads, daemon-as-cache** — the CLI, the hooks, and the stdio MCP server read the replicated JSONL shards directly and never touch the daemon. The HTTP daemon (`:7459`) is an optional query cache for HTTP-only consumers. Daemon down ⇒ primary contract unaffected (see "Daemon dependence" below). No SPOF.
4. **Open registries** — kinds.yaml, scopes.yaml, agents.yaml: adding a kind/scope/agent = YAML edit in the sync dir, enforced at emit time (archived scopes reject new events; unknown bare kinds are rejected when kinds.yaml is published; `org/name` extension kinds are always allowed). A `kinds.yaml` or `scopes.yaml` that is present but invalid — unreadable, not valid YAML, or rejected by the loader's checks (a name declared twice, an unknown status or severity, an unsupported `schema_version`) — blocks emit and `/push` (fail-closed); an absent file means no check. Exception: redaction rules are **compiled into the binary** — `redaction.yaml` documents them, so a synced (attacker- or typo-writable) file can never weaken redaction.
5. **Forced visibility** — failures must be **noisy**. Silence ≠ "all OK". Weekly green-light digest + dead-man heartbeat (independent process).

## Storage layout

```
~/Sync/activity/                          [Syncthing — cross-host source of truth]
  events-macbook.jsonl                    only macbook appends
  events-macmini.jsonl                    only mac-mini appends
  events-pc.jsonl                         only future PC
  events-<future-host>.jsonl              auto-detected new hosts
  scopes.yaml                             open registry
  kinds.yaml                              open registry  
  agents.yaml                             open registry
  redaction.yaml                          tier-1 regex pack

~/.local/share/activity-mesh/             [PER-HOST, NOT synced — store]
  index.db                                SQLite FTS5, rebuildable from JSONL
  cursors.json                            per-source byte-offset + head-hash for incremental ingest
  seq-<host>                              monotonic counter (persisted)
  audit/redactions-YYYY-MM.jsonl         redaction audit (metadata only — never the secret)

~/.local/state/activity-mesh/             [PER-HOST, NOT synced — runtime state + logs]
  clock-offset-ms                         cached SNTP offset (feeds clock_offset_ms)
  tokens-<session>                        L3 router per-session token budget
  last-health.json / last-digest.json    health + digest snapshots
  heartbeat-misses / *.log               dead-man state + all unit logs
```

**Two local dirs, never a third**: `~/.local/share` (the store) and
`~/.local/state` (runtime state + logs). Every supervisor unit sets
`ACTIVITY_MESH_HOME` to the former, `ACTIVITY_MESH_STATE` to the latter —
mixing them (an earlier bug) split health snapshots from the checks reading them.

**Why split source-of-truth (synced) vs derived (local)**:
- JSONL is append-only, idempotent — Syncthing's strong suit.
- SQLite has WAL semantics that **break on synced filesystems** ([SQLite docs explicit](https://www.sqlite.org/wal.html)). Each host rebuilds its own index from JSONL in seconds — cgo-free via `modernc.org/sqlite`, so the daemon cross-compiles like the other binaries.
- The audit log stores only `{ts, event, hits:[{type, len, sha256_first12}]}` — the secret itself is never written, so it is safe at rest by construction. (Optional `age` encryption of the audit dir is a documented future hardening, not yet implemented.)

## Event schema (JSONL, one line per event)

**Mandatory** (8 fields):

```json
{
  "v": 1,
  "id": "01HRX...ulid",
  "ts": "2026-05-04T15:23:45.123456Z",
  "host": "macbook",
  "agent": "claude-mac",
  "kind": "decision",
  "scope": "demo-app",
  "summary": "hard-capped at 500 chars (longer input is truncated + truncated:true), redacted, UTF-8 validated"
}
```

**Optional** (when applicable, omit otherwise — token economy):

```json
{
  "monotonic_seq": 47821,
  "ts_mono_ns": 184729384729384,
  "boot_id": "macbook-uuid",
  "session_id": "...",
  "parent_id": "01HRW...",
  "caused_by": "01HRV...",
  "actor": "assistant",
  "originator": "worker",
  "ref": "wiki://path | git://hash | file://relative",
  "tags": ["bug", "fix"],
  "duration_ms": 1842,
  "exit_code": 0,
  "files": ["..."],
  "truncated": false,
  "clock_offset_ms": 33,
  "priority": "P0|P1|P2|P3"
}
```

`clock_offset_ms` is the emitting host's clock skew (local − true, in ms) at
emit time. Emitters read it from the per-host cache
`<state>/clock-offset-ms` (state dir = `$ACTIVITY_MESH_STATE`, default
`~/.local/state/activity-mesh`), refreshed hourly by `activity-log
clock-sync` from the dead-man heartbeat. Cache missing/unparsable → field
omitted.

## 11 auto-capture sources

| source | mechanism | event kind |
|---|---|---|
| skill installed | fswatch `~/.claude/skills/*` create | `install` |
| plugin enabled/disabled | `settings.json` mtime + diff | `config` |
| memory entry added | fswatch `memory/*.md` create | `note` |
| wiki entry compiled | fswatch `wiki/<domain>/*.md` create | `compile` |
| inbox drop | fswatch `wiki/inbox/*.md` create | `handoff` |
| git commit | post-commit hook in watched repos | `project` |
| plugin updated | fswatch `~/.claude/plugins/cache/*/` mtime | `install` |
| daemon registered | fswatch `~/Library/LaunchAgents/*.plist` (glob configurable) | `config` |
| daemon restart | `launchctl list` 5min diff | `status` |
| agent config change | fswatch a configured config path | `config` |
| custom runtime post-task | your runtime's existing hook shells out to `activity-log emit` | `task` |

The watched paths and launchd label globs are declared in `configs/watcher.yaml`
— schema is data, so adapting to a different setup is a config edit, not a code
change.

**git capture**: `activity-log install-git-hook [--repo PATH]` writes (or
idempotently appends to) `.git/hooks/post-commit`, so every commit emits a
`project` event with the subject, short SHA, and a `git://` ref. It is not
auto-installed by the watcher — run it once per repo you want tracked.

## 5 read layers (invisible auto-pickup)

| layer | trigger | ambient toks | per-fire toks | how |
|---|---|---|---|---|
| **L1** schema | always | 48 | — | one-line in CLAUDE.md/AGENTS.md: "you have access to activity log via tool X" |
| **L2** SessionStart digest | session boot | 0 if no new events | 0-250 | hook (sessions with a tty only) injects ≤8 events of the last 24 h without canary/heartbeat, plus ≤5 `--kind error` events of the last 30 days, capped at 1000 chars |
| **L3** UserPromptSubmit ⭐ | regex match on prompt | 0 if no match | 0-500 | THE BREAKTHROUGH — fetches scoped slice automatically before LLM sees prompt |
| **L4** lazy MCP tool | agent autonomous call | 0 | +1500 on call | for deeper drill-down |
| **L5** Telegram push | severity ≥ P1 | 0 | 0 (out-of-band) | for P0 incidents when no session active |

### L3 — the invisible breakthrough

```
User: "что было сегодня"
  ↓ <80ms hook
regex matches "что было" + "сегодня" 
  ↓ sqlite3 query
fetch 12 events from today, format compact
  ↓
{additionalContext: "recent events: ..."}
  ↓
Claude responds naturally with awareness
```

**No visible tool calls. 0 tokens if intent doesn't match.**

#### Heuristic regex (Russian + English)

| intent | regex | scope |
|---|---|---|
| temporal recall | `что (было\|делал[а]?\|произошло)` ; `сегодня`, `вчера`, `за день\|неделю` ; `what (did\|happened)`, `today`, `yesterday`, `this week`, `recent` | digest of last N events in time window |
| status / current | `статус`, `чё там`, `что (в работе\|пендинг)` ; `status`, `pending`, `active tasks`, `what's going on` | active sessions + tasks + last 10 events |
| scope-named | known scopes from the generated `scopes-cache` (e.g. `demo-app`, `infra`, ...) | last 15 events in that scope |
| agent-named | agent aliases from the generated `agents-cache` (e.g. "what did <agent> do", any language) | last 10 events for that agent |
| incident | `incident`, `авария`, `падал`, `сломал`, `crashed`, `failed` | ≤5 `--kind error` events of the last 30 days |

**Anti-triggers** (suppress injection): `что такое X`, `как сделать X`, `напиши X` — these are definition / how-to / creation, not recall.

### L4 — MCP server

3 tools exposed:

```
activity_recent(scope?, agent?, host?, since?, limit=20) → events[]
activity_search(query, since?, until?, limit=20) → events[]
activity_digest(window="today" | "yesterday" | "<N>h" | "<N>d" | "since:ULID", group_by="scope") → markdown
```

## Token budget proof (tiktoken cl100k_base)

| scenario | L1 | L2 | L3 | total ambient |
|---|---|---|---|---|
| empty (no new events, normal coding question) | 48 | 0 | 0 | **48** |
| typical (4 overnight events, normal prompt) | 48 | 130 | 0 | **178** |
| recall query ("что было сегодня") | 48 | 0 | 360 | **408** |
| worst collision (resume + recall) | 48 | 250 | 500 | **798** rare |
| per-MCP call | 48 | 0 | 0 | +1500 on demand |

**Target ≤500 ambient: met for 99% of sessions.** Worst 798 only when user explicitly asked.

## Privacy redaction (two tiers live, NER planned)

Runtime rules are compiled into the binary (`pkg/redact`); `registries/redaction.yaml` is their human-readable documentation, not a runtime input. The one runtime-configurable piece: extra home-dir prefixes via `ACTIVITY_MESH_REDACT_HOMES`. `activity-log redact-shard` re-applies the current rules to the host's existing shard after a rule upgrade.

**Tier 1** (regex, <1ms, blocking): `sk-ant-`, `sk-`, `gh*_`, `glpat-`, `AIza`, Stripe, HuggingFace, `xox`, JWT, AWS, DB URLs, private keys, user paths, LAN IPs, emails, crypto keys. Applied to **all string fields**, not just summary.

**Tier 2** (entropy, 5-15ms, blocking): Shannon ≥4.5 on substrings ≥32 chars from base64-ish charset. Skip allowlist (UUIDs, git SHAs, plugin slugs starting with sk-).

**Tier 3** (NER, weekly batch — **planned, not yet implemented**): an offline NER model (e.g. GLiNER-pii-edge) scans the archive for PII the regex+entropy tiers miss; on a hit → alert + retroactive redact + rotate suspected creds. Tiers 1 and 2 run today; tier 3 is a v2 milestone (see `ROADMAP.md`).

Audit log: `~/.local/share/activity-mesh/audit/` stores only `{ts, event, hits:[{type, len, sha256_first12}]}` — never the original secret. (Optional at-rest `age` encryption of this dir is a documented future hardening.)

## Cross-OS support matrix

Windows is **CLI-only** by policy: the release zip ships `activity-log.exe`
plus registries — no watcher, no daemon, no scheduled tasks.

| component | mac | linux | win |
|---|---|---|---|
| storage JSONL (emit/query/compact/redact-shard) | ✅ | ✅ | ✅ |
| sync (Syncthing) | ✅ | ✅ | ✅ |
| capture watcher (fsnotify) | ✅ | ✅ | ❌ |
| HTTP query daemon (`:7459`) | ✅ | ✅ | ❌ |
| Claude Code hooks (L2/L3) | ✅ | ✅ | ❌ |
| health checks + heartbeat + weekly digest | ✅ launchd | ✅ cron/timers | ❌ |
| supervisor units via bootstrap | 6 launchd units | 2 systemd units | none |
| stdio MCP server | ✅ | ✅ | ✅ (CLI-backed) |

## Schema versioning + migration

Every event has `v: 1`. Reader maintains migration chain:

```python
# v1_to_v2.py
def migrate(event):
    if event["v"] == 1 and "old_field" in event:
        event["new_field"] = event.pop("old_field")
        event["v"] = 2
    return event
```

**Rules**:
- Field deletion forbidden (only deprecation)
- Rename = dual-write old+new for one minor version
- Major bump (v1→v2) requires coordinated rollout
- Archives never rewritten — readers adapt

## Daemon dependence (no SPOF — verified)

What actually talks to the daemon versus reading the JSONL shards directly:

| consumer | read path | when daemon (`:7459`) is down |
|---|---|---|
| `activity-log query` / `status` (CLI) | reads `events-*.jsonl` from the sync dir directly | **unaffected** — daemon is never in the path (scenario test: `tests/query_no_daemon_test.go`) |
| `activity-log emit` (CLI) | appends to the per-host shard directly | **unaffected** |
| L2/L3 hooks (`session-start-digest.sh`, `user-prompt-router.sh`) | shell out to the CLI | **unaffected** |
| stdio MCP server (`mcp/server.mjs` — Claude Code, Codex) | spawns the CLI per tool call | **unaffected** |
| any HTTP-only consumer (`/recent`, `/search`, `/digest`) | HTTP to the daemon | **down** — no automatic fallback |

The daemon binds `127.0.0.1:7459` by default (it serves the full history and
accepts unauthenticated `/push` writes); exposing it LAN-wide is an explicit
`--bind 0.0.0.0` / `ACTIVITY_MESH_BIND` decision. Every route answers 421
unless the `Host` header is `localhost` or an IP literal, so a DNS-rebound
page cannot reach it; remote clients use the IP address, not a host name.

`/push` contract: the event's `host` **must equal the daemon's own host** —
each shard has exactly one writer, so a client can never append to another
host's shard through HTTP (403 otherwise). The payload is validated (`v`, when
present, must be the integer schema version; `id` a strict ULID; `ts`
parseable, stored as canonical UTC and within years 0000–9999; `agent`,
`kind`, `scope` mandatory and label-safe; `priority` P0–P3; optional fields of
their declared types; nesting ≤32 levels; only numbers the index can read
back; body ≤64KiB → 413 above) and checked against the registries like a CLI
emit. The whole tree runs through the same write-time redaction as CLI emit,
then the summary is capped at 500 chars with `truncated: true`, and redaction
hits land in the same local audit log. Pushes are serialized, so a retried
ULID is appended once (`duplicate: true`). HTTP pushes are not a side door
around any write-path invariant.

**Index ↔ shard consistency**: the SQLite cache indexes exactly the live
shards. The ingest cursor stores a sha256 of the file prefix it has consumed;
any byte change under the cursor (compaction, `redact-shard`, sync replace —
including rewrites that keep the first line and don't shrink the file)
triggers a reconciling rescan: events are UPSERTed (stale payloads replaced —
FTS entries updated via triggers) and events missing from the shard are
deleted from the index. Archived events are therefore not searchable via the
daemon or MCP (`zcat` the archives instead), and an existing index always
converges to a fresh rebuild.

There is no client-side "auto-failover" logic, because the primary contract (CLI + hooks + stdio MCP) is local-first by construction and needs none — since the data layer is Syncthing-replicated JSONL, every host already holds every shard. The daemon is purely a cache/index for HTTP-only consumers; when it dies those consumers fail until the independent dead-man heartbeat alerts (RB-6 in the runbook). An earlier draft described a `daemon-config.yaml` primary/fallback chain with auto-failover — that was never implemented and is superseded by this table.

## Health checks (20) + dead-man heartbeat

`health/master.sh` runs the 20 checks in `health/checks/` four times a day
(launchd calendar at 00:44, 06:44, 12:44 and 18:44, never at login; cron or a
systemd timer on Linux). The checks run in parallel; those that read shards or
logs do it in one pass, not with a process per line. Each check prints one
JSON line with a tier: 0–1 ok or informational, 2 warn, 3 fail, 4 critical. A
check still running after `ACTIVITY_MESH_CHECK_TIMEOUT_S` (default 120 s) is
stopped and reported at tier 2 as "timed out". The run is saved to
`last-health.json` before anything is sent.

**Alerts**: when any check is at tier 2 or above, one alert lists every check
that is not ok. The same set of tier ≥ 2 checks is sent at most once per
`ACTIVITY_MESH_ALERT_REPEAT_S` (default 24 h); a different set goes out at
once, and a run with nothing at tier 2 or above resets it. Every alert sent by
the health runner or the heartbeat is appended to `alerts.log` in the state
dir, which the weekly digest counts. Alerts are plain text in one language:
Russian by default, English with `ACTIVITY_MESH_LANG=en`.

Checks that treat shard files as hosts or event streams read only live
shards; Syncthing conflict copies are the `conflict` check's business, except
in the two data-at-rest scans (`secrets-bypass`, `redactor-coverage`), which
read them too. A check whose input is missing says so: tier 2 when that is a
fault (no sync dir, no own shard, no `decay-state.json`), tier 0 when it is
normal (no archive yet, no digest on a secondary host).

- `adoption-ratio`: agent events per writer over 7 days
  (`ACTIVITY_MESH_ADOPTION_WINDOW_S`), with self-monitoring left out (the
  heartbeat agent, the `canary` and `heartbeat` kinds, the `activity-mesh`
  scope). Informational: always tier 1, `warn` for a single writer, no agent
  events or a top writer above 5:1.
- `archive-size`: uncompressed `.jsonl` older than 30 days in `<sync>/archive`
  → tier 2.
- `canary`: age of this host's newest heartbeat canary. Tier 3 when it is older
  than `ACTIVITY_MESH_CANARY_STALE_S` (2 h), or there is none, while the machine
  has been awake longer than that, so a night of sleep never fails it; the
  message carries the 24 h count and how many canaries got no daemon answer.
- `conflict`: Syncthing conflict files in the sync dir → tier 4.
- `decay-daemon`: last `compact` run (`decay-state.json`): tier 2 after 32 days,
  tier 3 after 40.
- `deploy-drift`: the source working copy (`ACTIVITY_MESH_SRC_DIR`) against
  `dist/current`, comparing `VERSION` and the shipped files of installers,
  health, registries, configs, hooks and mcp: tier 2 for one or two drifted
  areas at the same version, tier 3 otherwise; skipped without a checkout.
- `digest-freshness`: age of `last-digest.json`: tier 2 after 7.5 days, tier 3
  after 8.
- `hook-health`: error lines in the three hook logs (`session-start.log`,
  `user-prompt-router.log`, `redactor.log`) within the last 6 h
  (`ACTIVITY_MESH_HEALTH_WINDOW_S`, the run cadence): tier 2 for 1–5, tier 3
  above.
- `index-integrity`: `PRAGMA integrity_check` on `index.db` → tier 4 when it
  fails (tier 2 without `sqlite3`).
- `ingester-error`: within the same 6 h, daemon ingest errors in `daemon.err`
  (initial, periodic, pre- and post-push ingest) and watcher events lost in
  `watcher.err` (failed emits plus the events of dropped rollups); the worse of
  the two gives tier 2 above 2 and tier 3 above 10.
- `launchd-jobs`: on macOS, whether the six `com.activity-mesh.*` units are
  loaded: one missing is tier 2, more is tier 3.
- `redactor-coverage`: every line of every shard file re-scanned for PII the
  write path should have redacted (emails, JWTs, URLs with credentials,
  `/Users/<name>/`, LAN IPs): tier 2 for 1–2 lines, tier 3 above.
- `runtime-drift`: versions of the tools listed in `<sync>/compat-versions.txt`
  against the installed ones → tier 2 on drift.
- `schema-drift`: kinds and scopes of the last 24 h against `kinds.yaml` and
  `scopes.yaml`; `org/name` kinds and `ns:sub` scopes of a registered `ns` are
  allowed. Tier 2 for 1–4 unknown values, tier 3 from 5.
- `secrets-bypass`: every line of every shard file scanned for credentials that
  must never reach a shard (API keys and tokens, private key blocks) → tier 4,
  RB-2.
- `silence`: age of each host's shard: tier 3 above
  `ACTIVITY_MESH_SILENCE_MAX_S` (12 h, the same for every host). It does not
  judge within `ACTIVITY_MESH_WAKE_GRACE_S` (30 min) of boot or wake, and it
  lists hosts the owner switched off (the offline registry) at tier 1.
- `size-guard`: size of the sync dir: tier 2 above 400 MB, tier 3 above 500 MB.
- `sync-lag`: delivery lag `ctime − mtime` of each remote shard changed in the
  last day, counted from the wake when the file arrived after one: tier 2 above
  5 min, tier 3 above 10.
- `token-budget`: router injections (`injections.log`) and session totals:
  tier 2 when the largest injection exceeds the 500-token per-fire cap or a
  session exceeds 2000, tier 3 when the p95 does.
- `ulid-collision`: every ULID in every live shard → tier 4 on a duplicate.

**Dead-man heartbeat**: an independent job (launchd calendar, hourly at :20;
not part of the daemon) requests `/health` (`ACTIVITY_MESH_HEALTH_URL`, default
`http://127.0.0.1:7459/health`) and records the result as a `canary` event:
`ok=1`, or `ok=0` with `why=<cause>` and `busy=<0|1>`. After 3 misses in a row
(`HEARTBEAT_THRESHOLD`) it sends a fail alert through the same notifier as the
health runner, never through the daemon, at most once an hour
(`HEARTBEAT_COOLDOWN`). A timeout or empty reply while the load average is
above `CANARY_BUSY_LOAD` (12) is inconclusive and does not count as a miss.
**Catches the case where the daemon itself is dead.**

**Weekly digest**: on Sundays at 06:00 (launchd; cron on Linux), one message
with the week's events and the trend against the week before, how many of them
were self-monitoring, the canary failure share (timeouts on a busy machine are
listed but not counted), top scopes and agents, the alerts sent (from
`alerts.log`), the router's tokens per injection and per session against the
500 and 2000 caps, and events per host. The verdict comes from the last health
snapshot and drops to DEGRADED when more than 10% of the week's canaries failed.
So **silence is not ambiguous** — if you don't see the weekly digest, something's
wrong.

## Recovery runbook

9 procedures in `health/runbook/`:
- RB-1: activity dir corrupt
- RB-2: secret leaked into log (urgent)
- RB-3: Syncthing wholesale failure
- RB-4: hook auto-disabled, fallback growing
- RB-5: PC machine offline >12h
- RB-6: launchd plist won't load
- RB-7: schema drift unbounded
- RB-8: search latency runaway
- RB-9: mempalace+activity drift

Each has: symptoms → diagnosis → recovery steps → verification.

## Boundary rules (vs Maxim's existing 5 memory layers)

This layer **complements**, not replaces:

| layer | role | when to read |
|---|---|---|
| **MEMORY.md** | state truth (current rules, prefs) | "what IS the rule for X" |
| **Obsidian llm-wiki** | compoundable knowledge / decisions | "what's the pattern for X" |
| **activity-mesh** | raw event history | "WHEN did X happen / WHO did X" |
| **mempalace** | semantic recall projection | "things related to X" |
| **bridge channel memory** | isolated channel-agent state | channel-specific |

**Lookup order** (codified in CLAUDE.md):
1. State queries → MEMORY.md
2. Knowledge queries → wiki
3. Timeline queries → activity-mesh
4. Recall queries → mempalace
5. Channel queries → bridge memory

Activity-mesh **never claims to be state truth**. It's history. State derived from events via `tail | reduce` if needed, but MEMORY.md remains canonical.
