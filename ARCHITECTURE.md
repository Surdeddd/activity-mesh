# activity-mesh — Architecture v1

## Core principles

1. **Per-host shards** — each machine writes to `events-<host>.jsonl`. Single writer per file = zero Syncthing conflicts ever.
2. **Universal CLI is primary contract** — any agent/SDK works via shell-out. MCP/skills are optimizations on top.
3. **Local-first reads, daemon-as-cache** — the CLI, the hooks, and the stdio MCP server read the replicated JSONL shards directly and never touch the daemon. The HTTP daemon (`:7459`) is an optional query cache for HTTP-only consumers. Daemon down ⇒ primary contract unaffected (see "Daemon dependence" below). No SPOF.
4. **Open registries** — kinds.yaml, scopes.yaml, agents.yaml: adding a kind/scope/agent = YAML edit in the sync dir, enforced at emit time (archived scopes reject new events; unknown bare kinds are rejected when kinds.yaml is published; `org/name` extension kinds are always allowed). Exception: redaction rules are **compiled into the binary** — `redaction.yaml` documents them, so a synced (attacker- or typo-writable) file can never weaken redaction.
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
| **L2** SessionStart digest | session boot | 0 if no new events | 0-250 | hook reads delta `since last_seen_ulid`, injects ≤8 events with P1+ always shown |
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
| incident | `incident`, `авария`, `падал`, `сломал`, `crashed`, `failed` | P0/P1 events last 7 days |

**Anti-triggers** (suppress injection): `что такое X`, `как сделать X`, `напиши X` — these are definition / how-to / creation, not recall.

### L4 — MCP server

3 tools exposed:

```
activity_recent(scope?, agent?, host?, since?, limit=20) → events[]
activity_search(query, since?, until?, limit=20) → events[]
activity_digest(window="today" | "yesterday" | "7d" | "since:ULID", group_by="scope") → markdown
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
`--bind 0.0.0.0` / `ACTIVITY_MESH_BIND` decision.

`/push` contract: the event's `host` **must equal the daemon's own host** —
each shard has exactly one writer, so a client can never append to another
host's shard through HTTP (403 otherwise). The payload is validated (`v` must
be the supported schema version; `id` a strict ULID; `ts` parseable; `agent`,
`kind`, `scope` mandatory and label-safe; `priority` P0–P3; body ≤64KiB →
413 above), summaries are truncated to 500 chars with `truncated: true`, the
whole tree runs through the same write-time redaction as CLI emit, and
redaction hits land in the same local audit log. HTTP pushes are not a side
door around any write-path invariant.

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

## Health checks (19) + dead-man heartbeat

20 checks across categories:
- silence (per-host event freshness)
- conflict (Syncthing `.sync-conflict-*`)
- schema (drift in kinds/scopes vs registry)
- secrets (post-tier1 entropy/regex re-scan)
- size (>500MB warning)
- decay (compactor last-run age)
- launchd (daemon status)
- hook health (error rate)
- canary (per-host hourly heartbeat write)
- digest freshness (`generated_at` vs current event tail)
- token budget (ambient cost telemetry)
- adoption ratio (events per writer)
- redactor coverage (sampled NER cross-check)
- ULID collision detection
- sync lag per-host
- ingester error rate
- index integrity (FTS5 verify)
- archive size (>30d compression)
- runtime drift (Claude/Codex/Hermes version vs known)

**Dead-man heartbeat**: independent process (NOT same daemon) pings `/health` every hour. If 3 misses → tier-1 alert via Telegram bot using independent path. **Catches the case where the daemon itself is dead.**

**Weekly "all OK" digest**: every Sunday push to Telegram "system OK, X events captured, 0 incidents, last 5 P1 resolved". So **silence is not ambiguous** — if you don't see the weekly green, something's wrong.

## Recovery runbook

9 procedures in `health/runbook/`:
- RB-1: activity dir corrupt
- RB-2: secret leaked into log (urgent)
- RB-3: Syncthing wholesale failure
- RB-4: hook auto-disabled, fallback growing
- RB-5: PC machine offline >48h
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
