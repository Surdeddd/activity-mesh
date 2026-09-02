# Roadmap

## v1 — observability layer (this repo)

**Goal**: agents naturally know what other agents did, across machines, without explicit calls.

**Status**: implemented and deployed. All v1 phases (repo/docs, redaction, Go binaries, indexer + HTTP daemon + watcher, the 5 read layers, 20 health checks + dead-man heartbeat + weekly digest, cross-OS installers, open registries, memory-layer boundary rules) shipped across v0.1.0–v0.3.x. See `CHANGELOG.md` for the per-release record.

## v1.0 release gate (remaining)

- [x] Health checks green on both production hosts
- [x] Dead-man heartbeat alert path verified end-to-end (real Telegram delivery)
- [x] Token budget instrumented (per-injection + per-session telemetry, hard caps tested)
- [x] L3 hook: zero output when intent doesn't match (regression suite)
- [x] Tier-1 redactor covers the test-secret corpus; retroactive `redact-shard` exists
- [x] Redaction → shard rewrite → index convergence (payload + FTS purge) tested
- [x] Compaction → index convergence tested (archives excluded from the index everywhere)
- [x] `curl | bash` installs a complete system from a release archive (hermetic install test)
- [x] Release archives verified per platform (content tests; Windows is CLI-only)
- [ ] Soak: 30 days on two hosts with zero silent-red incidents
- [ ] Conflict-free verified: 1000 concurrent appends from 3 hosts → 0 sync-conflict files
  - [x] Single-machine half: 1008 racing appends across 3 shards assert exactly-once
        `monotonic_seq` allocation, no lost or doubled events, one writer per shard file
        and zero conflict copies (`tests/conflict_free_test.go`)
  - [ ] Cross-host half: the same run over a real Syncthing folder on 3 hosts

## v2 — action propagation (separate project, future)

**Goal**: when one agent does something, others can **adapt** automatically (not just know).

**Why separate**: different class of problem — orchestrator layer, not observability. v1 = read-mostly; v2 = write-mostly cross-system.

**Components**: event subscriptions → playbooks, per-host execution, approval gates, conflict resolution, rollback.

**When**: after v1.0 has 1+ month of production data showing which events would actually propagate.

Also deferred to v2: tier-3 NER redaction (offline batch scan of archives), `age` encryption of the local audit log.

## v3 — multi-tenant / federated (much later)

Explicitly out of scope for v1 and v2. Single-user / personal-infra is the focus; multi-user needs a real auth/signing/encryption layer and a different threat model.

## Long-term direction

The project deliberately stays focused on **personal AI infrastructure**. Not a SaaS, not a Mem0/Letta competitor, not enterprise memory. It is the missing *history* layer that ties together independent personal AI agents running on personal hardware.

## How to contribute

Issues and PRs welcome: docs, OS-specific install paths, real-world capture sources, health checks. The core write-path invariants (single writer per shard, locked append, write-time redaction) are load-bearing — changes there need tests proving the invariants hold.
