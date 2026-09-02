# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0-rc.3] — 2026-09-02

Health layer hardening after five weeks in production, plus the launchd
scheduling change that the on-demand-only incident forced.

### Fixed
- **Periodic launchd units no longer depend on `StartInterval`.** When
  launchd puts the gui domain into on-demand-only mode (observed under heavy
  swap), every StartInterval and RunAtLoad spawn stays pended for good; the
  health runner went 43 hours without a run and nothing could say so. The
  health and heartbeat templates now use `StartCalendarInterval`
  (0/6/12/18 at :44 and hourly at :20); calendar triggers keep firing in
  that mode.
- **Dead-man heartbeat separates "daemon dead" from "machine busy".** curl
  exit codes (7/28/52) name the cause; a timeout above `BUSY_LOAD` is logged
  as inconclusive and does not advance the miss counter. Load average is
  read as the first of the three values (macOS separates them by spaces).
- **`silence` and the weekly digest respect owner-disabled hosts** via the
  offline registry (`am_offline_hosts` in lib.sh): a host switched off on
  purpose is listed at tier 1 ok instead of paging every few hours.
- **Weekly digest** counts self-monitoring events separately from activity
  and reports the canary failure share over the week; above 10% the verdict
  drops to DEGRADED even when the last snapshot is green.
- **Alerts carry a severity.** `am_notify msg severity` exports
  `NOTIFY_SEVERITY` and passes `--severity` to notify-maxim, so digests stop
  being filed as failures.

### Added
- `deploy-drift` health check: source working copy vs `dist/current`
  (20 checks now).

## [0.4.0-rc.2] — 2026-07-27

Audit sweep over every subsystem (Go, shell, node) after v0.4.0-rc.1. 46 defects
found and confirmed; each fix below has a regression test that fails without it.

### Silent data loss (P0)
- **A shard drained to empty no longer strands its rows in the index.** The
  reconcile delete marshalled an empty seen-list as `null`, and
  `ulid NOT IN (SELECT value FROM json_each('null'))` is NULL for every row — so
  after `compact` archived *every* event, `/recent` and `/search` kept serving
  events that no longer existed in any shard.
- **Recursive watcher sources see directories created after startup.** The
  re-watch sat behind the op/pattern filters, and a new subdir never matches a
  file pattern like `*/SKILL.md` — so every recursive source silently froze on
  the tree that existed at boot. New subtrees are now walked (symlinks
  included), `w.Add` failures are logged and counted, and directories are no
  longer emitted as events in their own right.
- **A burst of filesystem changes is coalesced instead of dropped.** A bulk
  rewrite spawned one `activity-log emit` subprocess per file until the queue
  overflowed, then discarded the rest silently. Per-source budget + a rollup
  event carrying the coalesced count.
- **`compact` is crash-atomic across archive-then-rewrite.** Every archive
  touched in a run is truncated back to its pre-run size if any step fails, so
  an interrupted compaction no longer duplicates or corrupts archived history.

### Write path / daemon
- **`/push` assigns `monotonic_seq`** from the host counter and drops
  client-supplied `monotonic_seq` / `ts_mono_ns` / `boot_id`.
- **`/push` is idempotent per ULID** — a retry after a dropped response returns
  `duplicate: true` instead of appending a second shard line.
- **`/push` rejects browser-originated writes** (cross-origin `Origin`,
  `Sec-Fetch-Site`, form content types). Header-less scripted clients are
  unaffected.
- **`/push` enforces the registry** (archived scopes, unregistered kinds) and
  rejects junk-typed optional fields that would make an event undecodable to
  `activity-log query`.
- **A failed listener bind is fatal.** The daemon used to log it and keep
  running with no listener, which no supervisor would ever restart.
- **Reads no longer queue behind an ingest.** Queries use a separate WAL read
  pool; a query during a full rescan went from 4.7s to 0.4ms in the regression
  test.
- **Unparseable timestamps are skipped, not indexed at epoch 0**, where they
  were invisible to every time-windowed query. Count exposed as
  `activity_mesh_skipped_lines_total`.
- **The index survives its own documented rebuild.** Deleting `index.db` left
  `cursors.json` behind, which resumed mid-file and left the index permanently
  empty; a lost `events_fts` is now repopulated on open.

### Redaction
- PGP `PRIVATE KEY BLOCK` armour is matched (the enumerated prefix list missed it).
- Slack tokens are matched open-ended — the `{10,72}` cap left a plaintext tail.
- Telegram bot ids widened to 8–12 digits.
- `db_url` covers any scheme carrying userinfo (redis, amqp, https basic-auth),
  not just postgres/mysql/mongodb.
- New `hex_secret` rule for hex-encoded secrets bound to a secret-ish variable
  name — hex tops out at 4.0 bits/char and can never reach the entropy floor.
  Only the value is redacted; bare hashes are untouched.
- **JSON object keys are redacted**, closing the one path (`/push`) that accepts
  caller-controlled keys.
- `registries/redaction.yaml` now documents the tier-2 heuristic and the
  allowlist, and a parity test fails if it drifts from the compiled pack.

### CLI
- `~` is expanded and paths absolutised, so a quoted `--sync-dir '~/Sync/...'`
  no longer creates a literal `./~/Sync/...` the daemon never indexes.
- `$ACTIVITY_MESH_SYNC` / `$ACTIVITY_MESH_HOME` work without a `config.json`.
- An unreadable (not absent) registry now fails the emit instead of silently
  skipping validation — a fail-open gate is not a gate.
- `install-git-hook` resolves the hooks dir via `git rev-parse --git-path hooks`
  (worktrees, submodules, `core.hooksPath`), backs up an existing hook, and
  guarantees the exec bit.
- `clock-sync` rejects replies from unsynchronised servers (LI=3, stratum ≥ 16).
- Duplicate scope/agent/kind names in a registry are a loud error instead of
  last-wins, which could re-open emits to an archived scope.
- `compact` reports a failed decay-state write instead of discarding it.

### Shell / MCP / docs
- `bootstrap.sh --local` rebuilds binaries instead of keeping stale ones while
  re-pointing `dist/current`; builds go to a private temp dir; the smoke step
  warns on binary/asset version skew.
- `stat -c %Y` is tried before the BSD form — GNU `stat -f` prints a mount point
  and exits 0, which silently zeroed the `silence` and `sync-lag` checks on Linux.
- `dead-man-heartbeat.sh` honours `$ACTIVITY_MESH_BIN` (so `--prefix` installs work).
- `weekly-digest.sh` reads token telemetry from the state dir, not the dead
  `/tmp` path that pinned three metrics at zero.
- `update-session-end-flush.sh` can actually apply — its post-patch sanity check
  looked for a marker the injected block never contained.
- `mcp/install.sh` registers via `claude mcp add` (`~/.claude.json`) instead of
  a path Claude Code never reads, wires Hermes over stdio instead of a
  non-existent `/mcp` route, and refuses to duplicate a top-level `mcp_servers:` key.
- MCP server: multi-byte UTF-8 no longer corrupts on chunk boundaries,
  notifications are not answered, and `today`/`yesterday` are local days.
- RB-2 (secret leak) and five more runbooks rewritten against the shipped CLI —
  they referenced `reindex`, `archive`, `ingest`, `ulids` and installer paths
  that do not exist. A test now fails if docs name a command the binary lacks.

## [0.4.0-rc.1] — 2026-07-12

Release-candidate hardening: index/redaction consistency, honest reproducible
installs, real invariants at the write paths, synced docs. The per-host JSONL
shards + local SQLite cache architecture is unchanged.

### Privacy / index consistency (P0)
- **Retroactive redaction now purges the index.** Ingest upserts by ULID
  (INSERT..ON CONFLICT DO UPDATE) instead of INSERT OR IGNORE, and the FTS
  table gained UPDATE/DELETE triggers — after `redact-shard` + re-ingest,
  neither the SQLite payload nor any FTS entry contains the secret. Old DBs
  migrate on first open (CREATE TRIGGER IF NOT EXISTS).
- **Rewrite detection is byte-exact.** The ingest cursor (cursors.json v3)
  stores a sha256 of the consumed file prefix; ANY rewrite under the cursor —
  same first line, not-smaller file included — forces a reconciling rescan.
- **Compaction semantics defined: the index covers live shards only.** A full
  scan deletes events that left the shard (and their FTS entries) in the same
  transaction; `IngestDir` drops rows of vanished shard files. Archived events
  are readable via `zcat`, not via query/daemon/MCP. `raw_jsonl_path` /
  `raw_byte_offset` are updated on every rescan — never stale. Convergence
  tests pin: existing index == fresh rebuild after redact-shard and compact.

### Install & release (P0)
- **`curl | bash` is a complete, verified install.** Runtime assets (health
  scripts, unit templates, registries, watcher.yaml, hooks, MCP server)
  install to a versioned `~/.local/share/activity-mesh/dist/<version>/` with a
  `current` symlink; supervisor units reference `dist/current`, never a repo
  checkout. Any missing required asset, failed download, checksum mismatch, or
  unit-registration failure aborts with a non-zero exit — `bootstrap complete`
  prints only after full success. New flags: `--no-services`, `--local`,
  `--require-signature`; `ACTIVITY_MESH_BASE_URL` enables hermetic testing.
- **Honest signing claims.** sha256 is always verified; the cosign keyless
  signature of checksums.txt is verified when cosign is present (mandatory
  with `--require-signature`) and the script says plainly when it wasn't.
- **Release archives actually contain the runtime.** Fixed goreleaser globs
  (`dir/**/*` missed first-level files — health/master.sh, bootstrap.sh,
  configs/, hooks/ were absent from every previous archive); archives now
  ship binaries + health + templates + registries + configs + hooks + mcp +
  VERSION. `tests/release/test-archives.sh` pins the contents per platform.
- **Windows is officially CLI-only.** bootstrap.ps1 rewritten for the real
  release zip (sha256-verified, `activity-log.exe` + registries, correct
  `init --sync-dir ... --yes` flags, user PATH); the Task Scheduler daemon
  task that invoked a nonexistent `activity-log daemon` is gone, along with
  the taskscheduler templates; uninstall.ps1 matches. CI dry-runs both.
- Hermetic end-to-end install test (`make test-install`): fake release over
  local HTTP, temp HOME, `--no-services`; asserts binaries, versioned assets,
  rendered units without checkout references, seeded registries, queryable
  smoke event, and hard failure on checksum mismatch. Runs in CI on
  ubuntu+macos.

### Write-path invariants (P1)
- **/push enforces single-writer**: the event's host must equal the daemon's
  own host (403 otherwise) — HTTP clients can no longer write another host's
  shard. Schema version must match; `agent` is mandatory; kind/scope/agent
  are label-validated; priority is P0–P3; bodies >64KiB get 413 (previously
  silently truncated into "invalid json"); redaction hits are recorded in the
  local audit log exactly like CLI emits.
- **Registries are a real contract at emit**: archived scopes reject events,
  deprecated scopes warn, unknown bare kinds are rejected when kinds.yaml is
  published (namespaced `org/name` extensions always allowed); a broken
  registry file warns and never blocks writes.
- **Summary is hard-capped at 500 chars** on both emit and /push — truncated
  with `truncated: true`, never dropped; priority is validated everywhere.
- **redaction.yaml is documentation, not runtime config** (decision): rules
  stay compiled-in so a synced file can never weaken redaction; docs stop
  calling redaction data-driven. `ACTIVITY_MESH_REDACT_HOMES` remains the
  runtime-configurable piece.
- **secret-redactor is fail-closed**: a missing/failing binary now suppresses
  output and exits 1 instead of passing unredacted text through;
  `ACTIVITY_MESH_REDACTOR_MODE=open` restores passthrough with a loud
  warning. Hook suite covers both modes.

### MCP / telemetry / docs (P2)
- MCP: `activity_search` returns newest-first; `since:<ULID>` digest windows
  actually decode the ULID timestamp (garbage errors); server version comes
  from the VERSION file; binary resolution uses `darwin` (matching real
  artifact names — `macos` matched nothing); MCP tests are part of
  `make verify` and a dedicated CI job.
- Token telemetry split: the router logs per-injection tokens
  (`state/injections.log`, self-rotating) alongside the cumulative
  per-session cap file; the token-budget health check reports per-fire
  p50/p95/max against the 500 per-fire budget and the max session total
  against the 2000 cap (it previously compared session totals to the
  per-fire limit — red by design).
- Docs synced with reality: README support matrix + index semantics +
  retroactive redaction; ARCHITECTURE /push contract, prefix-hash
  reconciliation, honest redaction tiers, CLI-only Windows matrix; ROADMAP
  rewritten (v1 shipped, real release gate); installers/README + UPGRADE
  rewritten (versioned assets, real flags, no `reindex`/`--hours`/Task
  Scheduler fiction); stray legacy unit file removed.
- CI: `go test -race` in the OS matrix; new jobs — mcp tests, hermetic
  install test (ubuntu+macos), release-archive contents, bootstrap.ps1
  dry-run.

## [0.3.2] — 2026-07-07

Operability fixes surfaced by driving both hosts to green after the redeploy.

### Added
- `activity-log redact` (`--stdin`) — the standalone redaction filter
  `hooks/secret-redactor.sh` shells out to. It was never a real subcommand, so
  under launchd the redactor hook ran `activity-log redact --stdin`, got
  "unknown command", and emitted nothing — silently dropping the text it was
  meant to scrub-and-pass-through.
- `activity-log redact-shard` — re-applies the current redaction rules to this
  host's existing shard (atomic, under the host lock), scrubbing values that
  predate a rule change. Used to clean the per-host home path that the old
  hardcoded username never matched on the second host.

### Fixed
- **clock-sync tries several NTP providers** (google → cloudflare → apple →
  pool) instead of one hardcoded server, which failed wholesale on networks
  that block/mis-resolve it (VPN/split-DNS) — clock-sync had been failing
  hourly, leaving `clock_offset_ms` stale.
- **schema-drift is namespace-aware** and no longer flags the watcher's
  dynamic scopes: a `ns:sub` scope counts as known when the base namespace
  `ns` is registered, so registering `wiki` / `project` / `infra` covers every
  `wiki:<domain>` / `project:<repo>` / `infra:<component>` the watcher emits.

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
