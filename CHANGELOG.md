# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
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
