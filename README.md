# activity-mesh

> Shared activity log for multi-machine, multi-runtime AI agent setups. Agents see what other agents did — without explicit tool calls, without bloating context, across all OSes.

**Status**: v1 in development. MIT. Single-user / personal-infra focus.

## The problem

Run AI agents across multiple machines and runtimes — Claude Code sessions, custom agents on remote hosts, scheduled bots, CLI tools. Each agent has its own memory: provider auto-memory, project notes, vector stores, wiki-style knowledge bases.

**The gap**: when one agent does something important, other agents don't know. Cross-system awareness is missing. Existing options don't fit personal infra: vendor-locked SaaS (Mem0/Letta/Zep), heavy databases (Postgres), or ad-hoc shared files that drift.

## What it solves

A shared activity log that is:

1. **Auto-captured** — filesystem watchers + git hooks + session hooks emit events without agent intervention.
2. **Auto-injected** — `UserPromptSubmit` hook detects intent and injects a scoped slice into the agent's context invisibly. Empty when no events match.
3. **Token-cheap** — typical injection ~180 tokens; explicit budget envelope.
4. **Cross-machine** — per-host JSONL shards synced via Syncthing (zero conflicts by construction).
5. **Cross-OS** — single Go binary cross-compiled for macOS/Linux/Windows; YAML-described supervisors (launchd/systemd/Task Scheduler) and watchers (fswatch/inotify/USN).
6. **Coexists** — adds a *history* layer (when/who) on top of existing memory layers (state truth, knowledge, semantic recall) — clear boundary rules, no replacement.
7. **Self-monitoring** — 19 health checks, dead-man heartbeat (independent process), weekly digest, recovery runbook.
8. **Privacy-first** — 3-tier redaction (regex + entropy + NER) at write time, before file hits disk.

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
- **Open registries** (`kinds.yaml`, `scopes.yaml`, `agents.yaml`, `redaction.yaml`) — schema is data, not code.

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

`clock-sync` performs one SNTP round-trip (UDP to `time.apple.com`, 3s
timeout, pure Go) and atomically writes the rounded ms offset to
`$ACTIVITY_MESH_STATE/clock-offset-ms` (default
`~/.local/state/activity-mesh/`). Hosts running the dead-man heartbeat
(`health/dead-man-heartbeat.sh`, hourly via
`installers/templates/launchd-heartbeat.plist.tmpl`) refresh it
automatically; on hosts without the heartbeat schedule it with one cron
line: `0 * * * * /usr/local/bin/activity-log clock-sync`.

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
never silently dropped. Running daemons re-ingest the rewritten shard safely:
the index dedupes by ULID and rescans from offset 0 when the file shrinks.

A monthly launchd template ships in `installers/templates/launchd-compact.plist.tmpl`
(1st of month, 04:40, label `com.activity-mesh.compact`) — render the `{{...}}`
placeholders and `launchctl bootstrap` it yourself; `bootstrap.sh` does not install it.

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
health/                # 19 checks + dead-man heartbeat + master runner
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

## Roadmap

- v1: cross-machine sync, auto-context injection, MCP integration, health monitoring (current)
- v2: tier-3 NER redaction (offline weekly batch), digest snapshots, compactor for >90-day events
- v3: Linux + Windows installer parity, multi-runtime SDK adapters

See `ROADMAP.md` for detailed milestones.

## Inspiration

This project was inspired by **Andrej Karpathy's LLM Wiki** essay and his broader thinking on LLMs as compilers — separate the *spec source* (versioned schema, redaction rules, registries) from the *output artifact* (events). The same separation drives the design here: registries are spec; events are artifact.

## License

MIT.
