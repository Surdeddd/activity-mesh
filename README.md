# activity-mesh

> Your second agent session has no idea what the first one just did. activity-mesh gives them a shared activity log they read automatically — no tool calls, no MCP round-trip, ~180 tokens of context.

**Status**: v1 in development. MIT. Local-first, single-user. macOS/Linux first-class; Windows is CLI-only.

## The problem

You open a second terminal. Fresh session, empty memory. It doesn't know you refactored auth in the other window ten minutes ago, or that last night's scheduled agent already fixed that bug. So you re-explain — every time, in every window.

Memory tools solve *what you know*: state, project notes, embeddings. None of them solve *what just happened, and who did it*. That is a different layer — operational history — and every agent runtime drops it on session exit.

It compounds as you add agents. Different runtimes (Claude Code sessions, custom agents, cron bots, CLI tools), then different machines, each with its own private memory and no way to see the others. Existing options don't fit personal infra: vendor-locked SaaS (Mem0/Letta/Zep), heavy databases (Postgres), or ad-hoc shared files that drift.

## What it solves

A shared activity log that is:

1. **Auto-captured** — filesystem watchers + git hooks + session hooks emit events without agent intervention.
2. **Auto-injected** — `UserPromptSubmit` hook detects intent and injects a scoped slice into the agent's context invisibly. Empty when no events match.
3. **Token-cheap** — typical injection ~180 tokens; explicit budget envelope.
4. **Cross-machine** — per-host JSONL shards synced via Syncthing (zero conflicts by construction).
5. **Cross-OS** — single Go binary cross-compiled for macOS/Linux/Windows; YAML-described supervisors (launchd/systemd/Task Scheduler) and watchers (fswatch/inotify/USN).
6. **Coexists** — adds a *history* layer (when/who) on top of existing memory layers (state truth, knowledge, semantic recall) — clear boundary rules, no replacement.
7. **Self-monitoring** — 20 health checks, dead-man heartbeat (independent process), weekly digest, recovery runbook.
8. **Privacy-first** — two-tier redaction (compiled-in regex pack + Shannon-entropy heuristic) at write time, before a line hits disk, plus retroactive `redact-shard` for rule upgrades. (Offline NER is a v2 roadmap item.)

## How it works

```
┌─────────────────┐                         ┌─────────────────┐
│  host A         │   Syncthing             │  host B         │
│                 │ ◄────────────────────► │                 │
│  per-host JSONL │  per-host JSONL shards  │  per-host JSONL │
│  daemon :7459   │                         │  daemon :7459   │
│  MCP server     │                         │  MCP server     │
└────────▲────────┘                         └────────▲────────┘
         │                                           │
         │  query / emit / inject                    │
         │                                           │
   ┌─────┴─────┐                              ┌─────┴─────┐
   │  agent A  │                              │  agent B  │
   └───────────┘                              └───────────┘
```

- **Append-only** per-host JSONL shards (one host writes one shard, never two writers per file → zero merge conflicts).
- **ULID + monotonic_seq** for deterministic ordering.
- **SQLite + FTS5** indexer for sub-100ms search.
- **HTTP daemon** at `:7459` for query and emit; **MCP server** for IDE/agent integrations.
- **Open registries** (`kinds.yaml`, `scopes.yaml`, `agents.yaml`) — kinds/scopes/agents are data, enforced at emit time (archived scopes reject new events). `redaction.yaml` *documents* the redaction pack; the runtime rules are compiled into the binary so a synced file can never silently disable redaction.

## Quick start

```bash
# install (mac/linux)
curl -fsSL https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.sh | bash

# emit
activity-log emit --kind decision --scope project:foo --summary "switched to Bun.fetch"

# query
activity-log query --since 24h

# cache local↔NTP clock offset (fills clock_offset_ms on emitted events)
activity-log clock-sync

# query daemon (HTTP)
curl 'http://localhost:7459/recent?scope=project:foo&hours=24&limit=20'
curl 'http://localhost:7459/search?q=billing+oauth&limit=10'
curl 'http://localhost:7459/digest?window=today&group_by=scope'

# health
bash health/master.sh | jq .summary
```

`clock-sync` performs an SNTP round-trip (UDP, 3s timeout per server, pure
Go; tries several NTP providers in order) and atomically writes the rounded
ms offset to `$ACTIVITY_MESH_STATE/clock-offset-ms` (default
`~/.local/state/activity-mesh/`). Hosts running the dead-man heartbeat
refresh it hourly; elsewhere schedule
`0 * * * * /usr/local/bin/activity-log clock-sync`.

The daemon binds `127.0.0.1:7459` by default. `/push` accepts events only
for the daemon's own host (single-writer invariant), validates schema
version / ULID / timestamp / labels / priority, truncates summaries to 500
chars, and runs the same write-time redaction as the CLI.

## Router caches

The L3 router (`hooks/user-prompt-router.sh`) matches prompts against two
generated caches in `~/.config/activity-mesh/`:

- `scopes-cache` — one scope name per line; a prompt mentioning a project
  scope injects that scope's recent slice.
- `agents-cache` — `id⇥aliases⇥weak-aliases`; a prompt naming an agent (in
  any language, via its aliases) injects that agent's recent slice.

`activity-log refresh-caches` regenerates both from the registries — active
entries only, scopes minus those marked `router: false` (a scope name that
collides with an agent alias would otherwise double-filter `--scope`+`--agent`
to empty). It reads the live `<sync>/{scopes,agents}.yaml` when published
(falling back to the repo's `registries/`), writes atomically, and on any
read/parse failure leaves the existing caches untouched. `--dry-run` previews.
The dead-man heartbeat refreshes the caches hourly, so registry edits
propagate to every host without hand-editing. (`refresh-scopes` remains as an
alias for backward compatibility.)

## Shard compaction

Shards are append-only and grow unbounded; `compact` keeps the live file lean without losing history:

```bash
activity-log compact --dry-run     # report what would move, write nothing
activity-log compact               # archive events older than 90d (default)
activity-log compact --keep 30d    # custom retention window
```

Only this host's shard is touched (single-writer invariant). Events older than
`--keep` move, grouped by month, into `<sync>/archive/events-<host>-YYYY-MM.jsonl.gz`;
re-runs append additional gzip members, which plain `zcat` reads transparently.
The live shard is rewritten atomically (temp file + rename + fsync) under the
same per-host lock `emit` uses, and malformed lines are preserved verbatim —
never silently dropped.

**Index semantics**: the SQLite index covers exactly the **live** shards. Any
shard rewrite (compaction, `redact-shard`, a sync replace) is detected via a
prefix hash and triggers a reconciling rescan — changed events are updated in
place, and events that left the shard leave the index (and its FTS entries)
too. Archived events are not searchable through `query`, the daemon, or MCP;
read archives with `zcat`. An existing index always converges to what a fresh
rebuild would produce.

`bootstrap.sh` installs the monthly compact launchd job
(`com.activity-mesh.compact`, 1st of month 04:40) along with the other units.

**Retroactive redaction**: `activity-log redact-shard` re-applies the current
redaction rules to this host's shard in place (atomic, host-locked) — use it
after a rule upgrade to scrub values that predate it. The next ingest purges
the old payloads from the SQLite index and the FTS table as well.

## Building

```bash
make build         # cross-compile CLI + watcher + daemon for all targets (no cgo)
make build-daemon  # daemon for the current host only
make verify        # vet + test + shellcheck
```

All three binaries are **cgo-free** — SQLite (with FTS5) is provided by
[`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite), a pure-Go port —
so every binary cross-compiles for macOS/Linux/Windows from any host with a
single `go build`. Releases are cut with [GoReleaser](https://goreleaser.com)
(`.goreleaser.yaml`); the installer downloads the signed archive and verifies
its SHA-256 before installing.

## Layout

```
cmd/activity-log/      # Cobra CLI (init, emit, query, status, compact, clock-sync, refresh-caches)
cmd/activity-watcher/  # fsnotify capture daemon
server/                # HTTP query daemon (:7459)
pkg/event/             # ULID + monotonic_seq + redaction + sanitize
pkg/shard/             # the single locked shard-append primitive
pkg/redact/            # regex pack + Shannon entropy ≥4.5
pkg/index/             # SQLite FTS5 (cgo-free, modernc.org/sqlite)
pkg/registry/          # YAML loader/validator
mcp/                   # Node stdio MCP server
hooks/                 # SessionStart digest + UserPromptSubmit auto-context
health/                # 20 checks + dead-man heartbeat + master runner
installers/            # bootstrap.sh / .ps1 + launchd/systemd templates
registries/            # kinds / scopes / agents / redaction (generic examples)
```

## Layered memory model

activity-mesh is a single layer in a stack — it's the **history** layer. Recommended boundary:

| layer | role | example query |
|---|---|---|
| state truth | active rules, current preferences | "what's our policy on X?" |
| knowledge wiki | patterns, decisions, methodology | "how do we handle Y?" |
| **activity-mesh** | **operational history** | **"when did Z happen / who did Z?"** |
| semantic index | recall by association | "things related to X" |

History does not replace state truth. Don't cite activity events as canonical state — query the state layer first.

## Platform support

macOS and Linux are first-class — capture, injection, daemon, and monitoring all
run there. Windows is deliberately CLI-only (`activity-log.exe` emits and queries;
no watcher, daemon, or scheduled tasks).

Full capability matrix: [`docs/platforms.md`](docs/platforms.md).

## Roadmap

- v1 (shipped): cross-machine sync, auto-context injection, MCP integration, health monitoring, compaction, retroactive redaction, verified installers
- v2: tier-3 NER redaction (offline batch), action propagation groundwork
- v3: multi-tenant/federated — explicitly out of scope for now

See `ROADMAP.md` for the release gate.

## Inspiration

This project was inspired by **Andrej Karpathy's LLM Wiki** essay and his broader thinking on LLMs as compilers — separate the *spec source* (versioned schema, redaction rules, registries) from the *output artifact* (events). The same separation drives the design here: registries are spec; events are artifact.

## License

MIT.
