# Roadmap

## v1 — observability layer (this repo)

**Goal**: agents naturally know what other agents did, across machines, without explicit calls.

**Status**: in development. 8 phases.

| # | phase | days | status |
|---|---|---|---|
| P0 | repo + docs + scope | 1h | ✅ done |
| P1 | critical audit fixes (secret redactor + fswatch + boundary rules) | 1d | 🚧 in progress |
| P2 | Go writer binary cross-platform | 2d | pending |
| P3 | SQLite indexer + HTTP daemon + fswatch capture daemon | 1.5d | pending |
| P4 | 5 read layers (L1 schema, L2 SessionStart, L3 UserPromptSubmit invisible, L4 MCP, L5 Telegram push) | 2d | pending |
| P5 | 19 health checks + dead-man heartbeat + weekly "all OK" digest | 1d | pending |
| P6 | multi-OS install scripts (mac/linux/win) | 1d | pending |
| P7 | open registries (kinds.yaml/scopes.yaml/agents.yaml) | 0.5d | pending |
| P8 | integrate with Maxim's existing 5 memory layers (boundary rules) | 1d | pending |

**Total**: 8-10 days for full v1.

**MVP** = P0+P1+P2+P3+P4 (4-7 days) — invisible auto-context working end-to-end.

## v1 acceptance criteria (release gate)

Before tagging v1.0:
- [ ] All 19 health checks pass on macbook + mac-mini
- [ ] Dead-man heartbeat alerts on simulated daemon kill
- [ ] Token budget verified: ≤500 toks ambient typical, measured via tiktoken
- [ ] L3 UserPromptSubmit hook: 0 toks if intent doesn't match (verified on 50 random prompts)
- [ ] 10 real scenarios from `tests/scenarios/` pass end-to-end
- [ ] Tier-1 redactor catches 100% of test secrets (sk-ant, gh*, AWS, JWT, etc.)
- [ ] Cross-OS: bootstrap.sh deploys on macOS + Linux; bootstrap.ps1 on Windows
- [ ] Schema versioning: write v1 events, read with v2-aware reader, no breakage
- [ ] Recovery runbook 9 procedures documented in `docs/runbook/`
- [ ] Conflict-free verified: 1000 concurrent appends from 3 hosts → 0 sync-conflict files

## v2 — action propagation (separate project, future)

**Goal**: when one agent does something, others can **adapt** automatically (not just know).

**Why separate**: this is a different class of problem — orchestrator layer, not observability. v1 = read-mostly; v2 = write-mostly cross-system.

**Components**:
- Event subscription patterns (`activity-mesh subscribe --kind=install --action=playbook:install-everywhere`)
- Per-host playbooks (mac install path vs linux apt vs win choco)
- Approval gates (Maxim says yes before propagation)
- Conflict resolution (host A says install, host B says skip)
- Rollback procedures

**When**: only after v1 has 1+ month of production data showing actual install/decision events accumulated. Without that data, v2 is speculation.

**Pre-requisites**:
- v1 deployed and stable
- 100+ events captured per day on real Maxim setup
- Clear pattern of "events that should propagate" vs "events that shouldn't"

## v3 — multi-tenant / federated (much later)

**Goal**: multiple users/teams share an activity-mesh with proper isolation.

**Status**: explicitly out of scope for v1 and v2. Single-user/personal-infra is the focus.

**Why deferred**: requires real auth/signing/encryption layer, completely different threat model. Most multi-user orgs already use Slack/Notion for cross-team awareness — not the gap activity-mesh fills.

## Long-term direction

The project deliberately stays **focused on personal AI infrastructure**. We don't aim to:
- Become a SaaS product
- Compete with Mem0/Letta
- Solve enterprise multi-tenant memory
- Replace any existing memory system

We aim to be **the missing layer** that ties together independent personal AI agents running on personal hardware.

## How to contribute

While the project is in v1 development:
- Issues welcome for: design clarification, scenarios I missed, premortems
- Pull requests welcome for: docs improvements, OS-specific install paths, real-world test scenarios
- Code PRs gated until v1.0 tagged (preserving design coherence during initial implementation)

After v1.0 release: full open-source contribution model.
