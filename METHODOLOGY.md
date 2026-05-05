# Methodology

How activity-mesh was designed: agent swarm research + super-plan iteration + adversarial premortems.

## Built with Karpathy principles

This project applies the [60K-stars CLAUDE.md "4 principles"](https://github.com/forrestchang/andrej-karpathy-skills) directly:

1. **Think Before Coding** — surface assumptions and tradeoffs first
2. **Simplicity First** — minimum code that solves what was asked, no speculation
3. **Surgical Changes** — match existing conventions, don't refactor unbroken code
4. **Goal-Driven Execution** — define success criteria, loop until verified

Plus Karpathy's broader patterns:
- **LLM Wiki** — persistent compounding artifact (raw → wiki → schema)
- **Spec-driven development** — 5-10 line spec before any code
- **Token economy** — explicit budget per layer, no auto-injection
- **Lazy loading** — progressive disclosure (metadata first, content on demand)
- **Cross-vendor symbiosis** — Claude + Codex strengths combined where each excels

## Research process

### Phase 1: Multi-agent swarm survey (18 agents over 3 iterations)

Parallel agents on Claude Opus 4.7 surveyed:

**Industry frameworks**:
- Letta (formerly MemGPT) — multi-agent shared blocks model
- Mem0 — token-efficient retrieval (1.8K vs 26K context)
- Zep / Graphiti — temporal knowledge graph
- CrewAI memory layers
- AutoGen v0.4 / Microsoft Agent Framework
- MetaGPT message pool
- LangGraph state graphs
- OpenAI Assistants v2 / Responses API
- Anthropic Agent Skills

**Distributed systems patterns**:
- CRDT G-Set for append-only logs
- Vector clocks vs Lamport timestamps vs HLC
- Syncthing concurrent-append behavior
- Litestream SQLite replication
- Event sourcing best practices

**Storage backends**:
- SQLite FTS5 vs DuckDB vs Tantivy vs Meilisearch
- JSONL append-only semantics
- Per-host sharding vs shared writers

**Auto-context patterns 2026**:
- Anthropic Skills progressive disclosure
- MCP Resources vs Tools (auto-loaded vs called)
- UserPromptSubmit hook intent detection
- SessionStart hook delta digest
- Letta core memory blocks

**Privacy / redaction**:
- gitleaks regex patterns
- detect-secrets entropy heuristic
- GLiNER NER model (PII detection)
- Microsoft Presidio
- `age` encryption for audit logs

**Cross-OS reliability**:
- macOS launchd vs Linux systemd vs Windows Task Scheduler
- fswatch / inotifywait / NTFS USN journal
- Go cross-compilation matrix

### Phase 2: Use case enumeration

40+ real-world scenarios documented across 5 categories:
- Maxim's queries ("что было сегодня", "статус")
- Agent autonomous queries ("did claude-mac install X?")
- Cross-agent awareness (install propagation, handoffs)
- Forensic / audit (post-mortem, who did X at T)
- Maintenance / lifecycle (decay, archive)

### Phase 3: Adversarial premortems

Three pre-mortems caught failure modes:
- **Premortem v1** (12 modes): adoption asymmetry, Syncthing conflicts, privacy leaks, schema drift, hook crash, mempalace overlap, token bloat, PC paths, trust erosion, decay missed, launchd dead, search latency
- **Premortem v2** (30+ edge cases): clock pathologies, filesystem corner cases, schema drift, concurrency races, multi-agent semantic conflicts, recovery scenarios, scale at year 5
- **Premortem v3** (12 visible-failure modes): hook over-injection, intent false negatives, stale digest, layer interaction bugs, alert fatigue silent death, runbook overload, retro-PII unsync, runtime drift

Each pre-mortem produced concrete spec deltas folded into design before deploy.

### Phase 4: Extensibility stress tests

10 hypothetical scenarios tested:
- Add 6th machine (Linux PC)
- Add new agent SDK (Gemini/Ollama)
- Add new event kinds
- Temporary scopes with TTL
- Agent retired/disabled
- 10× volume increase
- Schema breaking change in 2027
- HTTP daemon down
- Federated team (multi-tenant) — explicitly **scoped out** for v1
- Compliance export

v2 design scored 5.5/10 extensibility. v3+v4 refinements raised to 8.5/10 via:
- Schema versioning baked in
- Open registries (kinds/scopes/agents YAML)
- Platform abstraction layer
- Universal CLI as primary contract
- Two-tier emit (signal + trace) for scale
- Daemon-as-cache pattern

### Phase 5: Honest scope decision

Critical: **v1 is observability, not action propagation.**

User originally asked "Hermes installed plugin → Claude installs it too automatically". This is **action propagation**, a different class of problem requiring an orchestrator layer (event subscriptions → playbooks → cross-host execution → approval gates). v1 deliberately scopes this out and documents it in [ROADMAP.md](./ROADMAP.md) as v2.

Honesty over wishful coverage. Better a sharp v1 that delivers than a vague v1 that overpromises.

## Decision log

Key decisions during design with rationale:

| decision | options considered | chosen | why |
|---|---|---|---|
| Storage path | `~/Obsidian/llm-wiki/activity/` vs `~/Sync/activity/` | own folder | semantic separation: knowledge vs operations |
| Sync mechanism | Syncthing / git / Litestream / iCloud / Tailscale rsync | Syncthing per-host shards | zero conflicts by construction; existing infra; no cloud |
| Index | DuckDB / SQLite FTS5 / Tantivy / Meilisearch / grep+jq | SQLite FTS5 + ripgrep fallback | built-in macOS/Linux; rebuildable; <50ms p95 at 100K events |
| Clock ordering | NTP / Lamport / HLC / vector clock | ULID + monotonic_seq | overkill avoided; sufficient for 100 events/day |
| Read pattern | always-on / push / pull / hybrid | 5-layer hybrid (L1-L5) | invisible auto-pickup via L3, lazy MCP via L4 |
| Schema enum | closed bounded / open registry | open registry with lifecycle | extensibility |
| Privacy | regex only / NER only / 3-tier | 3-tier (regex + entropy + NER) | layered defense |
| Daemon model | single primary / per-host / cloud | daemon-as-cache (every host can run) | no SPOF |
| Multi-tenant | v1 / v2 / never | explicitly v3+ | proper auth/signing layer needed |

## What this project deliberately does NOT do

To preserve focus and avoid scope creep:

- **NOT a memory system replacement** — Mem0/Letta/Zep stay where they are; this is an orthogonal layer
- **NOT action propagation** — v1 only knows; v2 (separate project) will act
- **NOT multi-tenant** — single-user/personal-infra focus
- **NOT a chat/conversation store** — those go to bridge memory; this is event metadata
- **NOT a wiki** — Obsidian llm-wiki handles compounding knowledge
- **NOT a state-of-world store** — MEMORY.md is canonical; activity log is history
- **NOT cloud-dependent** — fully offline-capable; opt-in cloud backup only

## Bibliography

Primary sources consulted during research:

### Karpathy
- [LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
- [Sequoia Ascent 2026 keynote summary](https://karpathy.bearblog.dev/sequoia-ascent-2026/)
- [Context engineering tweet](https://x.com/karpathy/status/1937902205765607626)
- [autoresearch repo](https://github.com/karpathy/autoresearch)
- [nanochat repo](https://github.com/karpathy/nanochat)
- Forrest Chang's [andrej-karpathy-skills CLAUDE.md](https://github.com/forrestchang/andrej-karpathy-skills) (60K stars)

### Frameworks
- [Letta multi-agent shared memory](https://docs.letta.com/guides/agents/multi-agent-shared-memory)
- [Mem0 State of AI Agent Memory 2026](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [Zep Graphiti](https://github.com/getzep/graphiti)
- [CrewAI memory docs](https://docs.crewai.com/en/concepts/memory)
- [LangGraph persistent memory](https://focused.io/lab/persistent-agent-memory-in-langgraph)

### Distributed systems
- [Syncthing — Understanding Synchronization](https://docs.syncthing.net/users/syncing.html)
- [SQLite FTS5 docs](https://www.sqlite.org/fts5.html)
- [SQLite WAL on network FS](https://www.sqlite.org/wal.html)
- [DuckDB vs SQLite benchmark](https://www.lukas-barth.net/blog/sqlite-duckdb-benchmark/)
- [Litestream — Streaming SQLite Replication](https://litestream.io/)
- [DeepMind embedding ceiling 2025](https://www.marktechpost.com/2025/09/04/google-deepmind-finds-a-fundamental-bug-in-rag-embedding-limits-break-retrieval-at-scale/)

### Privacy / redaction
- [knowledgator gliner-pii-edge-v1.0](https://huggingface.co/knowledgator/gliner-pii-edge-v1.0)
- [Microsoft Presidio](https://github.com/microsoft/presidio)
- [gitleaks rule pack](https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml)
- [age encryption](https://age-encryption.org)

### Anthropic
- [Claude Code Skills](https://code.claude.com/docs/en/skills)
- [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks)
- [Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Equipping agents for the real world with Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Prompt cache 5-min TTL](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)

### MCP
- [Model Context Protocol Resources](https://modelcontextprotocol.io/specification/2025-06-18/server/resources)
- [MCP Tools spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
- [MCP Tool Search 85% reduction](https://www.atcyrus.com/stories/mcp-tool-search-claude-code-context-pollution-guide)

### AGENTS.md ecosystem
- [agentsmd.org spec](https://agents.md/)
- [Anthropic Skills as open standard (2025-12-18)](https://github.com/anthropics/skills)

## Verification approach

Per Karpathy's "Goal-Driven Execution" principle:

- **Every phase has explicit acceptance criteria** before code is written
- **Verification commands run before claiming completion**: shellcheck, py_compile, plutil -lint, dry-run
- **Real-data tests** — not just unit tests, but end-to-end smoke tests on Maxim's actual setup
- **Premortem-driven** — top 5 silent+corrupting failures get specific design choices, not "we'll handle it"
- **Token budget proven** — measured via tiktoken, not estimated

This methodology, applied iteratively, is what makes activity-mesh **bulletproof rather than aspirational**.
