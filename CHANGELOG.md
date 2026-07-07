# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] — 2026-07-07

Robustness polish from the remaining audit findings.

### Fixed
- **Watcher event loop no longer stalls under burst.** `runEmit` (which forks
  `activity-log emit`, up to 10s) moved off the fsnotify select loop onto a
  bounded per-source worker, so a slow/missing binary can't back up the loop
  and let the kernel event buffer overflow (silently dropping events). A
  full queue logs a drop instead of blocking.
- **clock-sync rejects implausible SNTP replies.** A valid-looking reply
  implying a >24h skew or a negative/huge round-trip is refused rather than
  cached — it would have poisoned every event's `clock_offset_ms`.
- **Watcher config fails loud on typos.** An unknown `op:` value (e.g.
  `created`) and a non-boolean `recursive:` (e.g. `yes`) previously loaded
  silently and then matched nothing / defaulted to false; both are now load
  errors. `diff_field` is documented as reserved (parsed, not yet acted on).

## [0.3.0] — 2026-07-07

Security + correctness hardening, cgo-free builds, and a genericised,
publishable repo. Deployed to both hosts.

### Security (P0)
- **Lost-append race fixed.** `emit` now holds the per-host flock across the
  whole seq→marshal→append sequence, and compaction holds it across its
  read→rewrite→rename — so an append can no longer land inside a rewrite and
  be destroyed. New `pkg/shard.AppendLocked` is the single append primitive
  used by both the CLI and the daemon (regression-tested with `-race`).
- **`/push` hardened.** The host label is validated against the shard
  filename alphabet (path-traversal guard — `"host":"../.."` previously wrote
  to arbitrary files), the `id` must be a strict ULID, `ts` is parsed, and the
  payload runs through the same redaction pipeline as CLI emit before being
  written (pushes were a side door around redaction). Extended schema fields
  now survive the round-trip.
- **Daemon binds `127.0.0.1` by default** (`--bind` / `ACTIVITY_MESH_BIND` to
  widen) — it served the full history and accepted unauthenticated writes on
  all interfaces.

### Redaction
- `sk-` gets a left word-boundary (prose like "risk-assessment-…" was
  irreversibly mangled); `lan_ip` requires all four octets (version strings
  like "10.15.7" no longer false-positive, and real `10.a.b.c` addresses no
  longer leak their last octet); `user_path` is built at runtime from `$HOME`
  + `$ACTIVITY_MESH_REDACT_HOMES` (no hardcoded username).
- New credential patterns: `gho_`/`ghu_`/`ghr_` GitHub, `glpat-` GitLab,
  `AIza` Google, `sk/rk_live|test` Stripe, `hf_` HuggingFace.

### Indexer
- Cursor identity (v2): a first-line hash is stored with the byte offset, so a
  shard rewritten to a size still larger than the cursor (compaction, or a
  Syncthing replace) forces a full rescan instead of silently skipping the
  unread tail. Reads are incremental (`Seek`, not whole-file). Ingested count
  uses `RowsAffected` (dedup no longer inflates it). Multi-word FTS queries no
  longer require adjacency. Cursor entries for deleted shards are GC'd.

### cgo-free
- SQLite swapped from `mattn/go-sqlite3` to `modernc.org/sqlite` (FTS5
  compiled in). All three binaries are now cgo-free and cross-compile for
  macOS/Linux/Windows from any host — no build tags, no native daemon matrix.

### Router / hooks
- Agent intent is driven by a generated `agents-cache` (`refresh-caches`
  renders it from `agents.yaml`: id / aliases / weak-aliases). Fixes Cyrillic
  agent names (e.g. "антон") never matching, and removes the hardcoded agent
  list from the hook. `refresh-scopes` → `refresh-caches` (alias kept).
- Session digest excludes monitoring noise structurally (`--exclude-kind
  canary,heartbeat`) instead of a substring grep. `jq` is resolved via PATH
  then the usual homes. `secret-redactor.sh` gained the `~/.local/bin`
  fallback (it silently ran in pass-through — no redaction — under launchd).

### Health / operability
- **Real alerting.** `am_notify` routes through `ACTIVITY_MESH_NOTIFY_CMD` →
  `notify-maxim` → direct Telegram, and surfaces undeliverable alerts on
  stderr — a missing notifier no longer means weeks of silent red. No
  hardcoded chat id anywhere (creds via env / `TELEGRAM_ENV`).
- De-noised permanent reds: `digest-freshness` threshold 2h → 8d (writer is
  the weekly job; absent snapshot on a secondary host is OK, not a fail);
  `decay-daemon` 14d → 40d (compact is monthly) and `compact` now writes
  `decay-state.json`; `token-budget` reads the router's real state path;
  `schema-drift` matches the actual `- name:` YAML shape (it flagged every
  event, including registered kinds); `launchd-jobs` checks all six units with
  an `ACTIVITY_MESH_EXPECTED_JOBS` override.
- Heartbeat canary emits the registered `activity-mesh` scope (was the
  unregistered `infra:heartbeat`, ~half of all events).

### MCP
- `initialize` negotiates the client's protocol version (supports
  2025-06-18 / 2025-03-26 / 2024-11-05); all tools carry read-only
  annotations; `activity_search`'s description is honest (substring scan, not
  FTS5); `activity_digest`'s `yesterday` is a bounded calendar day.

### Universal / publishable
- `registries/{scopes,agents}.yaml` are now generic examples (real
  personalised copies live only in the sync dir); no private infrastructure,
  chat ids, or personal paths in shipping code, templates, or docs.
- `.goreleaser.yaml` (v2): all binaries × all platforms, sha256 checksums,
  SBOM, cosign keyless signing; release workflow on tag push. `bootstrap.sh`
  downloads the archive, **verifies its sha256**, installs all six supervisor
  units, and seeds registries into the sync dir. Supervisor templates use one
  two-dir contract (`ACTIVITY_MESH_HOME` store vs `ACTIVITY_MESH_STATE`) —
  fixing the split that starved the health snapshots.
- Docs reconciled with reality: cgo-free build, bind + `/push` behaviour, the
  two-dir contract; `age`-encrypted audit and tier-3 NER are now honestly
  marked "planned, not yet implemented".

### Added
- `activity-log install-git-hook [--repo PATH]` — installs an idempotent
  `post-commit` hook emitting a `project` event per commit (a capture source
  documented since v1 but never shippable before).
- `activity-log --version`.

## [Unreleased]

### Added
- `activity-log compact` — shard compaction for this host's
  `events-<host>.jsonl`. Events older than `--keep` (default `90d`, same
  duration syntax as `query --since`) move, grouped by month, into
  `<sync>/archive/events-<host>-YYYY-MM.jsonl.gz`; when a monthly archive
  already exists the batch is appended as an additional gzip member
  (concatenated members are valid gzip, plain `zcat` reads them). The
  live shard is rewritten atomically (temp file in the same dir + fsync +
  rename) while holding the same per-host exclusive flock the emit path
  uses (`seq-<host>`); malformed / blank / unterminated lines are
  preserved verbatim, never archived, never dropped. `--dry-run` reports
  without writing; `--sync-dir` overrides the configured sync directory.
  Daemon-safe by construction: the indexer dedupes by ULID
  (`UNIQUE` + `INSERT OR IGNORE`) and resets its byte cursor to 0 when a
  shard shrinks, so the post-compaction rescan inserts no duplicates.
- `installers/templates/launchd-compact.plist.tmpl` — monthly launchd
  job template (1st of month, 04:40, label `com.activity-mesh.compact`).
  Template only; `bootstrap.sh` does not load or install it.
- `activity-log clock-sync`: minimal pure-Go SNTP client (one UDP
  round-trip to `time.apple.com`, 3s timeout, no new dependencies) that
  measures the local clock offset and atomically writes the rounded ms
  value to `<state>/clock-offset-ms` (state dir = `$ACTIVITY_MESH_STATE`,
  default `~/.local/state/activity-mesh`). On network failure it exits
  non-zero and leaves the previous cache untouched. The dead-man
  heartbeat now refreshes the cache hourly (best-effort).
- Emitters populate the schema's `clock_offset_ms` field — declared
  optional since v1 but never written — from that cache on every
  `event.New`. Semantics: local − true, in ms (positive = local clock
  ahead). Missing/unparsable cache → field omitted; no error, no log
  spam.
- Black-box scenario test `tests/query_no_daemon_test.go` proving
  `activity-log query` / `status` return correct results from a fresh
  sync dir with no daemon running (untagged, runs under plain
  `go test ./...`).
- `activity-log refresh-scopes` — regenerates the L3 router's
  `scopes-cache` (`$ACTIVITY_MESH_CONFIG`, default
  `~/.config/activity-mesh/`) from the scopes registry instead of
  hand-maintaining it. Registry resolution: `--registry PATH`, else the
  canonical live copy `<sync>/scopes.yaml` (the Syncthing-replicated
  location `health/checks/schema-drift.sh` already reads), else the
  repo-checkout seed `./registries/scopes.yaml`. Writes active scopes
  only, minus those marked `router: false`, atomically (temp file +
  rename); on read/parse failure it exits non-zero and leaves the
  existing cache untouched. `--dry-run` prints the would-be content;
  every run prints a one-line summary (N written, M excluded). The
  dead-man heartbeat now refreshes the cache hourly (best-effort, same
  pattern as `clock-sync`).
- Scopes registry: optional per-scope `router: false` (default true)
  excludes a scope from the router cache. Set on `hermes`, `viktor`,
  `claude-mac`, `anton` — the names that collide with the router's
  agent-intent names (`AGENT_FILTER` case-arms in
  `hooks/user-prompt-router.sh`); with both intents active the router
  double-filters `--scope`+`--agent` to an empty slice. Also registered
  the previously hand-cached-only `rentier` and `deploy` scopes so the
  generated cache is a superset of the old hand-written whitelist.

### Fixed
- `installers/templates/launchd-heartbeat.plist.tmpl` set
  `ACTIVITY_MESH_STATE={{LOG_DIR}}`, so a template-rendered heartbeat
  wrote the `clock-sync` offset cache (and miss counters) into the *log*
  dir while env-less emitters read the default state dir
  (`~/.local/state/activity-mesh`) — the offset never reached emitted
  events. Now uses a `{{STATE_DIR}}` placeholder with a comment pinning
  the correct render value; note that `bootstrap.sh`'s `$STATE_DIR`
  variable is the `~/.local/share` store dir and must not be reused
  verbatim here (bootstrap does not render this template). The same
  stale pattern still exists in `launchd-health.plist.tmpl` and
  `launchd-weekly-digest.plist.tmpl` (flagged here, deliberately not
  changed in this pass).
- ARCHITECTURE.md claimed daemon failure triggers "automatic fallback to
  local" via a client lib. Traced the real paths: the CLI, both read
  hooks, and the stdio MCP server read the JSONL shards directly and
  never contact the daemon — no fallback exists because none is needed.
  Only HTTP consumers (Hermes MCP variant, ad-hoc `curl`) depend on
  `:7459`, with no auto-failover. The "Daemon-as-cache" section is
  replaced by a per-consumer dependence table; the unimplemented
  `daemon-config.yaml` primary/fallback design is marked superseded.
- README quick-start showed `activity-log query --hours 24` — the flag
  does not exist; corrected to `--since 24h`.
- L3 `user-prompt-router.sh` was silently dead: it invoked `activity-log
  query` with flags the v0.2.0 CLI no longer exposes, so every intent
  produced an empty slice (stderr swallowed by `2>/dev/null`, stdout
  empty → silent exit). Remapped to the current CLI surface
  (`--agent --format --host --kind --scope --since --limit`):
  - `--format compact` → `--format text` (only `text|json` are valid),
    reviving the `temporal` / `scope` / `agent` intents.
  - `status` intent `--status active` → `--kind status --since 48h`
    (no `--status` flag exists; status is now a first-class `kind`).
  - `incident` intent `--priority "P0,P1" --since 7d` →
    `--kind error --since 30d` (no `--priority` flag; `error` is the
    incident `kind`, and the window is widened because error events are
    rare — a 7d window is empty in practice).
  - `scope` intent now passes `--since 30d` (was the CLI default of 24h).
    Project-scoped events are infrequent, so a 24h window made named-scope
    recall almost always empty. The router still no-ops gracefully when
    `~/.config/activity-mesh/scopes-cache` is absent, but with a populated
    cache (one bare scope per line) prompts mentioning a project name now
    inject that project's recent slice.
- L2 `session-start-digest.sh` was silently dead for the same reason: it
  called `--format digest` / `--format ulid` (only `text|json` exist),
  `--since-ulid` and `--priority` (no such flags). The CLI has no ULID
  cursor and `--since` takes only durations, so the per-session
  ULID-delta is gone; the digest now queries a 24h recent window plus
  `--kind error --since 30d` for incidents. Header unchanged.
- `nextSeq` read the monotonic-counter file via a second handle
  (`os.ReadFile(path)`) while holding an exclusive lock on the first.
  On Windows `LockFileEx` is a mandatory byte-range lock, so that read
  failed ("another process has locked a portion of the file") — the
  Windows `test` CI job had been red since v0.2.0. Now reads from the
  locked handle (`io.ReadAll(f)`); behaviour is unchanged on POSIX.
- Both read hooks resolved the `activity-log` binary only via `command -v`,
  which misses it under launchd / non-interactive shells that lack
  `~/.local/bin` on PATH (e.g. the Mac-mini agents) — so the hooks silently
  no-op'd there. Added a `$HOME/.local/bin/activity-log` fallback to both
  hooks' binary resolution.
- `activity-watcher` recursively added an fsnotify watch for every
  subdirectory of a recursive source, including `node_modules`, `.git`,
  vendored binaries and caches. On a node_modules-heavy tree
  (`~/.openclaw/agents`) this consumed 61k+ file descriptors and hit
  `kern.maxfilesperproc`, wedging the watcher with "too many open files"
  so it silently stopped emitting. Recursive walks now skip dependency /
  VCS / build / cache dirs (`skipWatchDir`), at both init-walk and the
  runtime create-watch path.

## [0.2.0] — 2026-05-06

### Added
- Bilingual (EN + RU) alert payloads across all telemetry scripts. Every
  alert now carries the English original on top, a `━━━` separator,
  and a Russian translation below — so any operator can read it without
  language coin-flip.
- `npm_token` redaction pattern (regex + Go rule). `npm_xxx`-shaped
  tokens are now caught at write-time before the JSONL shard is
  flushed.
- Canary event emission inside `health/dead-man-heartbeat.sh`. The
  hourly heartbeat now appends a `kind=canary` event to the local
  shard, which closes the monitoring loop for the canary check.
- `weekly-digest.sh` writes a JSON state file
  (`$STATE/last-digest.json`) alongside the human-readable markdown
  snapshot, so the `digest-freshness` health check has a stable signal
  to read.

### Fixed
- `am_host()` in `health/lib.sh` now returns the full hostname
  (`os.Hostname()`-equivalent) so canary, sync-lag, and silence checks
  resolve the local shard correctly. The previous short alias
  (`macbook` / `mac-mini`) did not match the on-disk shard naming used
  by the Go writer.
- `health/master.sh` produced false-negative `canary` failures because
  the heartbeat was alert-only and never emitted a shard event. Fixed
  in the canary-emission change above.

### Changed
- README rewritten to focus on the problem and the architecture instead
  of any specific user's agent setup. Added an attribution to Andrej
  Karpathy's LLM Wiki essay and his LLMs-as-compilers framing.

## [0.1.0] — 2026-04

### Added
- Cobra-based CLI: `activity-log init | emit | query | status`.
- ULID + monotonic sequence event ordering with deterministic replay.
- 3-tier redaction: regex pack (Anthropic, OpenAI, GitHub, AWS, Slack,
  Telegram, JWT, PEM, DB URLs, ETH, BTC, email, user paths, LAN IPs),
  Shannon-entropy heuristic on base64-shaped substrings, NER stub for
  the offline weekly tier.
- SQLite + FTS5 indexer for sub-100ms full-text search.
- HTTP query daemon at `:7459` with `/health`, `/recent`, `/search`,
  `/digest` endpoints.
- `fsnotify`-based capture daemon scanning 11 source kinds out of the
  box.
- Node-based MCP stdio server exposing 3 lazy tools for any MCP
  runtime.
- Claude Code hooks: `SessionStart` digest + `UserPromptSubmit` router
  that injects a scoped slice of recent activity invisibly when intent
  matches.
- 19 health checks (silence, canary, sync-lag, secrets-bypass, hook
  health, ULID collision, schema drift, etc.) plus an independent
  dead-man heartbeat process and a weekly green-light digest.
- Open registries: `kinds.yaml`, `scopes.yaml`, `agents.yaml`,
  `redaction.yaml` — schema is data, not code.
- Cross-OS installers for macOS / Linux / Windows with launchd /
  systemd / Task Scheduler templates.
- Layered memory integration with explicit boundary rules: state truth,
  knowledge wiki, activity history, semantic recall.

[Unreleased]: https://github.com/Surdeddd/activity-mesh/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Surdeddd/activity-mesh/releases/tag/v0.2.0
[0.1.0]: https://github.com/Surdeddd/activity-mesh/releases/tag/v0.1.0
