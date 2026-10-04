# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0-rc.8] — 2026-10-04

Fixes from a full audit of every subsystem on top of rc.7. The watcher stops
losing events to its own timeout, health alerts stop paging for bugs in the
checks, a credential is redacted before the summary is cut, and the installer,
MCP server and uninstall are hardened.

### Security
- **A credential cut by the 500-character cap no longer reaches the shard.**
  The summary was truncated before redaction, so a `db_url` near the limit
  lost its `@host`, the rule stopped matching, and the password went to the
  synced shard in plain text, on CLI emit and on `/push` alike. The whole
  event is now redacted first and the summary capped afterwards; redaction
  markers can no longer push it past 500 characters, and the audit log also
  records hits beyond the cap.
- **Redaction catches more.** Your home directory and the homes listed in
  `ACTIVITY_MESH_REDACT_HOMES` are redacted even with a non-ASCII user name
  (`/Users/josé`, `C:\Users\Максим`), every occurrence of each, nested or
  overlapping ones included; other users' home paths are not redacted.
  Hex secrets longer than 64 digits, hex values behind a quoted name
  (`"SLACK_SIGNING_SECRET": "…"`), `SECRET_KEY_BASE`, and hex string values
  under a secret-named key of a structured `/push` field are caught too.
  `git@host:owner/repo` SSH remotes are no longer redacted as email
  addresses; any other `user@host:path/` still is.
- **The daemon answers only `localhost` and IP-literal hosts.** A page on an
  attacker's domain re-pointed at 127.0.0.1 (DNS rebinding) passed the
  `Origin == Host` check and could read `/recent` and `/search` and write
  `/push`. Every route now answers 421 to any other `Host` header.
- **`secrets-bypass` and `redactor-coverage` scan every line.** secrets-bypass
  looked at the last 30 minutes of a 6-hour cadence (and at most 200 lines),
  so most leaks were never seen; the "random" sample of redactor-coverage was
  always the oldest 100 lines. Both now scan whole shard files, Syncthing
  conflict copies included, since a copy is replicated like a live shard. A
  historical hit keeps `secrets-bypass` critical until the line is scrubbed
  (RB-2). `redactor-coverage` does not count the `git@host:owner/repo`
  remotes the redactor keeps, so a commit message naming a remote no longer
  pages.
- **`uninstall.sh` follows `ACTIVITY_MESH_HOME` and `ACTIVITY_MESH_STATE`, and
  `--purge` removes only directories that positively look like
  activity-mesh's own.** Honouring the variables lets a typo point `rm -rf`
  anywhere, so every candidate is checked before anything changes. `dist`
  always, and with `--purge` the store, state and config dir, must not be a
  mount point or a volume root and may hold only what activity-mesh creates
  there; the store, state and config dir must also hold a file activity-mesh
  writes. An empty directory is removed with `rmdir`, never `rm -rf`; if
  something has appeared in it since the check, the uninstall stops and
  deletes nothing more. A value that is your home or one of its parents, a
  sync dir, a parent of one or anything inside one, or a parent of the default
  dirs is refused, compared by resolved name and, except for "inside a sync
  dir", by device and inode (on macOS also through the `/System/Volumes/Data`
  spelling), and the uninstall stops when it cannot read an identity. Blanks
  around a sync dir value are trimmed. A purge through a chain of links
  removes the links that lead to the purged dir and no other, so a path that
  leads to a file or to nothing loses no link, and a dir that was not there
  at the check is left alone even if it appears during the run. A refusal
  names what is in the way; see
  [installers/README.md](installers/README.md#uninstall).

### Fixed
- **The watcher no longer loses events to its own emit timeout.** It killed
  `activity-log emit` after 10 seconds, while a loaded machine needs minutes,
  so the share of lost watcher events grew from 7% in August to 27% in early
  October. The limit is now 10 minutes, and an emit that printed its ULID
  counts as written even when it exits late: the CLI appends the event before
  it prints the ID.
- **Files inside a moved-in or copied-in directory are reported.** They
  produce no events of their own, so they are announced once the directory is
  watched, within the per-source budget. A directory on the skip list
  (`node_modules`, `.git`, `dist`, `build`, `vendor`, `target`, ...) is
  ignored when it appears at runtime, as at startup, so a source folder
  literally named one of those stays invisible by design.
- **A source keeps reporting after its root is replaced.** Renaming or
  deleting the watched root left the source deaf until a restart. It now waits
  for the root to come back, re-attaches with a fresh watcher, announces what
  the new root holds, and logs a failed re-attach once per outage.
- **The watcher uses the CLI its unit points at.** `ACTIVITY_MESH_BIN`, set by
  the installed units, wins over `activity_log_bin` in `watcher.yaml`, so a
  custom `--prefix` no longer emits through a missing or stale
  `~/.local/bin/activity-log`.
- **Health alerts stop paging for check bugs.** Since mid-September an alert
  went out almost every run, about four a day, and each cause was a bug in a
  check; the items below fix them. On top of that, the same set of failing
  checks is sent at most once per 24 hours (`ACTIVITY_MESH_ALERT_REPEAT_S`; a
  value that is not a positive number means 24 hours), a new failure goes out
  at once, an all-clear resets it, and every alert sent is recorded in
  `alerts.log`.
- **A health run cannot be stalled by one check.** Checks forked a process per
  line, and a run took 5 to 21 minutes; the checks now read shards and logs in
  one pass. `master.sh` enforces its own per-check timeout
  (`ACTIVITY_MESH_CHECK_TIMEOUT_S`, default 120 s) without GNU `timeout`,
  which macOS lacks, and reports a check past it at tier 2 as "timed out".
  Without `lib.sh` it exits with a message instead of crashing, and the
  snapshot is saved before the notifier runs.
- **Health is not silent without `jq`.** The checks printed nothing and
  `master.sh` exited without a snapshot or an alert. Every check now reports
  itself failed ("jq not found"), and the run sends an alert that it failed.
- **`adoption-ratio` is informational.** It counted the heartbeat as a writing
  agent and paged on the ratio. It now leaves self-monitoring out, looks at 7
  days, reports a fractional ratio and stays at tier 1.
- **`canary` tells a sleeping laptop from a broken writer.** It counted
  canaries per 24 hours, so every night of sleep looked like a launchd
  failure. It now fails only when the newest canary is older than
  `ACTIVITY_MESH_CANARY_STALE_S` (2 h) while the machine has been awake longer
  than that, and a burst of other events can no longer push the canaries out
  of the lines it reads. A canary line whose summary is not a string no
  longer makes it, or the weekly digest, read as if there were no canaries.
- **`silence` and `sync-lag` stop blaming the network for sleep.** silence
  waits `ACTIVITY_MESH_WAKE_GRACE_S` (30 min) after boot or wake before
  judging, and sync-lag counts delivery from the wake when the file arrived
  after it. The per-host silence thresholds were keyed on names no real shard
  has; `ACTIVITY_MESH_SILENCE_MAX_S` (12 h) now applies to every host, which
  was already the effective value.
- **`hook-health` and `ingester-error` read the right logs.** hook-health
  counted clock-sync failures from `heartbeat.log`; it now reads only the
  three hook logs, over the 6-hour run window instead of one hour.
  ingester-error read an `ingest.log` that nothing writes; it now counts
  daemon ingest errors in `daemon.err`, pre-push ingest included, and lost
  watcher events in `watcher.err`: failed emits plus dropped rollups.
- **`schema-drift` and `ulid-collision` judge every event they should.**
  schema-drift flagged `org/name` kinds, which emit always allows, and
  ulid-collision saw only the last 1000 lines; it now scans whole shards. One
  shared timestamp parser converts `+03:00`-style offsets to UTC and survives
  non-string values in every check that windows events by time.
- **The daemon-down alert is plain text in one language.** The dead-man
  heartbeat sent markdown with an English and a Russian copy glued together
  and claimed history was being lost, although CLI writes do not need the
  daemon. Its canary now records why the probe failed (`why=…`, `busy=…`).
- **The weekly digest reports real numbers.** Alerts come from `alerts.log`
  (the count was always 0), the token budget compares the average injection
  with the 500-token per-fire cap and the largest session with the 2000-token
  cap, canary timeouts on a busy machine are listed but not counted as
  failures, and the "self-heals" line, which had no source, is gone.
- **Health and heartbeat no longer start at login.** After a reboot, health
  ran for 21 minutes in the boot peak and the heartbeat recorded a miss while
  the daemon was still indexing. Both launchd units now wait for their
  calendar slot.
- **The prompt router keeps its token caps.** It checked the 2000-token
  session cap before adding the next injection, so sessions reached about
  2400, and the `…[truncated]` marker pushed an injection past 500. An
  injection now gets the smaller of 500 and what is left of the 2000, marker
  included, and with less than 100 left the router stays silent without
  querying. A zero-padded counter is read as decimal; `0800` used to crash the
  hook.
- **`/push` refuses lines the index could not read back.** A payload nested
  deeper than 32 levels, a number outside the float64 range, a fractional
  `duration_ms`, `exit_code` or `clock_offset_ms`, a non-string `priority`, a
  non-integer `v`, trailing data or a bare `null` now gets 400, and large
  integers stay exact instead of being rounded through float64. Such a line
  used to be appended but never indexed, so every retry appended it again.
- **Retries of one ULID append once.** `/push` is serialized and indexes its
  own shard before the duplicate check, so concurrent retries, and a retry
  after a crash between the append and the indexing, get `duplicate: true`.
- **`/health` answers during a slow start.** The daemon opens its port before
  the initial ingest; after a reboot the port opened 14.5 minutes late and the
  heartbeat counted a miss. Events from healthy shards are counted even when
  another shard fails to ingest.
- **Pushed timestamps are stored as canonical UTC.** `+03:00` and nanosecond
  forms are rewritten to `2006-01-02T15:04:05.000000Z` so they sort like every
  other event. A time whose UTC form would leave the years 0000–9999 is
  refused, because no reader could parse the stored form.
- **`--limit N` returns the newest events.** `query` sorted by the raw `ts`
  text, so offset and nanosecond forms landed out of order, and the index
  ordered by whole seconds, so a limit could drop the newest event within a
  second. The CLI now orders by the parsed time, then sequence and ULID; the
  index by second, then canonical `ts`, then ULID.
- **One malformed line no longer stops indexing.** A line nested deeper than
  SQLite accepts rolled back the whole pass, and `IngestDir` gave up at the
  first failing shard, so every later host went unindexed while `/health`
  said ok. Such lines are skipped and counted in
  `activity_mesh_skipped_lines_total`, which now also counts lines SQLite
  rejects; the other shards are indexed, and vanished shards are still swept.
- **Syncthing conflict copies are not read as shards.**
  `events-<host>.sync-conflict-….jsonl` matched the shard glob: `query` and
  `status` double-counted, the index re-pointed rows at the copy, and silence,
  sync-lag and the digest showed the copy as a host. The CLI, the index, the
  daemon's watcher and the health checks skip copies now; the `conflict`
  check still reports them at tier 4.
- **`redact-shard` expands `~` and keeps numbers exact.** `--sync-dir '~/…'`
  read a path that did not exist and reported success; a host without a shard
  is now an error (exit 1) instead of `0 of 0`. A rewritten line keeps its
  number literals byte for byte, and a line with trailing data is left as it
  is.
- **`curl | bash` no longer downgrades and half-installs.** GitHub's
  `releases/latest` skips prereleases and pointed at v0.3.2, so the
  documented install replaced 0.4.0-rc binaries with 0.3.2 ones and then
  failed on the missing `health/`. `bootstrap.sh` and `bootstrap.ps1` now
  take the newest release including prereleases, and `bootstrap.sh` refuses
  an archive without the full runtime layout before anything changes. The
  binaries are staged first (the first step that may ask for `sudo`),
  `dist/current` is switched, and only then are the binaries renamed into
  place, so a bad archive or a refused password changes nothing.
- **A bootstrap re-run keeps the configured sync dir.** Every run reset
  `sync_dir` to `~/Sync/activity`; it is now read from `config.json` with its
  JSON escapes decoded, and a value that cannot be decoded stops bootstrap
  with a hint to set `ACTIVITY_MESH_SYNC`.
- **Linux upgrades restart the services**, so an upgrade runs the new
  binaries instead of leaving the old processes up.
- **`bootstrap.sh` follows `ACTIVITY_MESH_HOME` and `ACTIVITY_MESH_STATE`** and
  passes them on to the binaries it runs; the install test no longer writes
  into live directories when those variables are exported.
- **Smaller bootstrap fixes.** `--no-services` on macOS renders units into
  `dist/<version>/units/` instead of `~/Library/LaunchAgents`, which launchd
  loads at every login; the cosign identity is pinned to the release workflow
  on a tag; a missing checksum entry names the archive; `curl | bash` no
  longer fails on `BASH_SOURCE`; a relative `--prefix` is made absolute; an
  unset `USER` is tolerated; values with `&`, `\`, `<` or `>` survive
  rendering (XML-escaped in plists); the download dir is removed on exit; and
  the `PATH` warning names the `activity-log` that actually wins.
- **The MCP server starts when launched through a symlink** such as
  `dist/current`, which is how the installer registers it; it used to exit
  without a word.
- **The MCP digest refuses windows it does not know.** `activity_digest`
  takes `today`, `yesterday`, `<N>h`, `<N>d` (up to five digits) and
  `since:<ULID>`; anything else used to return a 24-hour digest. Tool failures
  come back as `isError: true` results, an unknown tool is JSON-RPC error
  -32602, a request line that is not an object with a method gets -32600 (a
  `null` line used to crash the server), resource URIs are percent-decoded,
  and a scope named `constructor` no longer breaks the digest.
- **Install scripts write through symlinks and keep permissions.** A
  `CLAUDE.md`, `settings.json` or session-end hook kept in a dotfiles repo was
  replaced by a regular file with other permissions; edits now land in the
  link's target, atomically, with its mode. The `MEMORY.md` path is derived
  from `$HOME` instead of the author's; the Codex
  `[mcp_servers.activity-mesh]` table is replaced in place (sub-tables,
  neighbours and comments kept, a backup written, a re-run changes nothing)
  instead of being appended a second time, and a dotted or inline definition
  elsewhere is refused with the block to paste; `--help` prints usage instead
  of applying the patch, and an unknown flag exits 2. The five scripts share
  one helper, `installers/lib/cfgedit.sh`, which ships in the archive, and a
  script started through a symlinked directory finds the files next to the
  real script.
- **The uninstall removes what the install registered.** It also removes the
  binaries from `~/.local/bin`, and the Claude Code hooks and MCP
  registrations (`claude mcp remove`, `~/.claude.json`, the Codex table) that
  point into the `dist/` it deletes, backing up each edited file;
  registrations that point elsewhere, such as a repo checkout, stay, and a
  Hermes entry is only reported. `uninstall.ps1 -Purge` also removes the state
  dir.

### Changed
- **A registry file that is present but invalid blocks writes.** A
  `kinds.yaml` or `scopes.yaml` that is present but invalid — unreadable, not
  valid YAML, or rejected by the loader's checks (a name declared twice, an
  unknown status or severity, an unsupported `schema_version`) — blocks emit
  and `/push`; an absent file means no check. The code has behaved this way since rc.2; it is now a
  decision (fail-closed, asserted by `TestEnforceRegistryBrokenYAMLFailsClosed`)
  and supersedes the rc.1 note that "a broken registry file warns and never
  blocks writes". Failed watcher emits show up in `ingester-error`.
- **Alerts and the digest use one language:** Russian by default, English
  with `ACTIVITY_MESH_LANG=en`, never both glued into one text.
- **Docs follow the code.** ARCHITECTURE describes all 20 health checks, the
  per-check timeout, the alert repeat rule, the Host filter and the `/push`
  contract as they are now; RB-4 and RB-5 give the real hook-health window,
  the silence threshold and the offline registry; RB-2 covers the
  `redact-shard` exit code and secrets in conflict copies. README shows the
  real `make build` matrix (a cross-compile smoke check; releases build the
  full set) and what `make verify` runs; `installers/README.md` and
  `installers/UPGRADE.md` describe the install order and the uninstall rules,
  and `mcp/README.md` the digest windows, error shapes and what
  `mcp/install.sh` writes.

### Added
- `make test-health` and a `health-tests` CI job run a hermetic regression
  suite for the health checks (bash and jq, temp dirs only); `make verify`
  includes it. `make test-install` also runs the new suites for the shared
  helper, the integration installers and the uninstall.

### Upgrade notes
- **Re-run bootstrap on every host.** It re-renders the units: health and
  heartbeat stop running at login, and the watcher gets `ACTIVITY_MESH_BIN`.
  An existing `~/.config/activity-mesh/watcher.yaml` keeps its old
  `activity_log_bin` line, which is harmless once the unit sets
  `ACTIVITY_MESH_BIN`. Pass `TELEGRAM_ENV` again if your alerts use a file
  other than `~/.config/activity-mesh/telegram.env`; every run renders the
  default otherwise.
- **HTTP clients must address the daemon by IP or `localhost`.** A DNS name
  (`<host>.local`, a Tailscale name) now gets 421. Check
  `ACTIVITY_MESH_HEALTH_URL` on every host before upgrading; the heartbeat
  template sets `http://127.0.0.1:7459/health`.
- **Rebuild the index after resolving conflict copies.** Rows that an older
  daemon indexed from a Syncthing conflict copy stay until the copy is
  deleted or the index is rebuilt, and deleting the copy also drops the
  events that daemon re-pointed at it from the index until the next rebuild
  (see "Rebuilding the index" in [installers/UPGRADE.md](installers/UPGRADE.md)).
- **The first health run after the upgrade sends any standing alert once.**
  rc.7 stored no alert signature, so a failure at tier 2 or above that is
  already there goes out on that run; from then on the same set of failing
  checks is sent at most once per 24 hours.
- **`/push` is stricter.** Clients that sent a non-integer `v`, fractional
  integer fields, a non-string `priority` or trailing data get 400; the hooks
  in this repo write through the CLI and are not affected.
- **`redact-shard` exits 1 on a host without a shard**, and
  **`uninstall.sh --purge` may refuse a directory it used to delete**, listing
  what is in the way; remove such a directory by hand if that is what you
  want.

## [0.4.0-rc.7] — 2026-09-13

### Fixed
- **Health alerts carry a source label and go out once.** The weekly digest
  glued an English and a Russian copy of the same text plus a timestamp
  footer; it now sends a single Russian text. `am_notify` exports
  `NOTIFY_LABEL=activity-mesh`, so the report bot names the sender instead of
  a generic header.
- **The health summary is no longer a priority alert.** It used `critical=`
  as a key, and that word alone made every health alert a priority one that
  went straight to the DM. The counts are now spelled out.

## [0.4.0-rc.6] — 2026-09-02

### Fixed
- **`sync-lag` measures Syncthing delivery, not event cadence.** It compared
  `now` with the remote shard's mtime, which Syncthing preserves from the
  source, so an hourly heartbeat alone produced "lag" of up to an hour and a
  napping host paged tier 3 several times a day. Delivery lag is now
  `ctime - mtime` of the synced shard (ctime is set on receipt and cannot be
  preserved); a quiet host is the `silence` check's business.
- **Session-start digest skips headless sessions.** Every `claude -p` run
  (scheduled agents, delegates) fired the digest — about 2 000 injections a
  month for nobody. A session without a controlling tty is logged as
  `headless` and gets no context; `ACTIVITY_MESH_SESSION_TTY` overrides the
  detection for tests.
- **Prompt router drops self-monitoring events.** Its queries now pass
  `--exclude-kind canary,heartbeat` like the digest already did, so an
  injected slice no longer carries "hourly heartbeat ok=1" lines.

## [0.4.0-rc.5] — 2026-09-02

### Fixed
- **`deploy-drift` compares only the files a release ships.** Release archives
  omit `mcp/README.md`, `mcp/install.sh` and the test file, so the rc.4 check
  reported the mcp area as drifted on every release install and would have
  paged every six hours. Source-only extras are ignored; a shipped file that
  is missing or differs in the source tree still counts as drift.
- **`bootstrap.sh` no longer kickstarts the heartbeat at install time.** The
  daemon needs ~30 s to index before it listens, and the immediate probe
  recorded a false miss; the hourly calendar run covers it.

## [0.4.0-rc.4] — 2026-09-02

### Fixed
- **`bootstrap.sh` kickstarts the watcher, daemon and heartbeat after
  bootstrapping them.** With launchd in on-demand-only mode a freshly
  bootstrapped KeepAlive/RunAtLoad unit never starts on its own: the rc.3
  install left the daemon down until a manual `launchctl kickstart`. Explicit
  demand spawns go through in that mode.

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
