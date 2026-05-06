# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
