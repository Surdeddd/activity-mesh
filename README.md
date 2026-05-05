# activity-mesh

> Cross-agent activity layer for multi-machine, multi-runtime AI agent setups. Agents naturally know what other agents do — without explicit tool calls, without bloating context, across all OSes.

**Status**: v1 in development. Open source (MIT). Single-user / personal-infra focus; multi-tenant explicitly out of scope.

## The problem

You run multiple AI agent systems across multiple machines:
- **Claude Code** sessions on macbook + mac-mini
- **Hermes Agent** on mac-mini
- **OpenClaw** swarm of 13 specialized bots on mac-mini
- **Codex** (Виктор) bot via codex-harness
- *future*: Linux PC, Windows machine, new SDKs (Gemini, Ollama, ...)

Each system has **its own memory** — Claude Code auto-memory, Hermes SOUL.md, OpenClaw shared/KB, mempalace MCP, Obsidian llm-wiki, bridge channel memory. Total: 5+ parallel memory layers.

**The gap**: when one agent does something important, **other agents don't know**. You ask Claude on macbook "что Hermes делал на mac-mini" — Claude has no idea. You install a plugin on macbook in evening, ask Hermes about it next morning — Hermes can't see it. You git-commit a project, OpenClaw bot doesn't notice. Cross-system awareness is missing.

**Existing solutions don't fit**:
- Mem0/Letta/Zep — vendor lock, monthly bill, designed for cloud-first SaaS
- Postgres — daemon dependency, single point of failure
- Slack/Notion — out of scope, not personal-infra
- DIY ad-hoc files — drift, conflicts, no auto-pickup

## What activity-mesh provides

A **shared activity log** that:
1. **Auto-captures important events** without agent intervention (filesystem watchers, git hooks, session hooks, tool trackers — 11 sources today)
2. **Auto-injects relevant context** when agents need it (UserPromptSubmit hook detects intent, fetches scoped slice, injects invisibly)
3. **Costs ~0 tokens ambient** when no events are relevant (typical: 178 tokens; empty: 48; worst: 798 — explicit budget envelope)
4. **Syncs across all your machines** via Syncthing (per-host shards = zero conflicts ever)
5. **Survives all OSes** — macOS, Linux, Windows (single Go binary cross-compiled, abstraction YAML for supervisor/watcher)
6. **Layers on top of existing memory systems**, not replaces them — clear boundary rules: state truth → MEMORY.md, knowledge → wiki, history → activity-mesh, semantic → mempalace
7. **Self-monitors and self-heals** — 19 health checks, dead-man heartbeat (independent process), weekly "all OK" digest, recovery runbook
8. **Privacy-first** — 3-tier redaction (regex + entropy + NER) at write time, before file even hits disk

## Quick start (will be live after P2)

```bash
# install (mac/linux)
curl -fsSL https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.sh | bash

# emit event manually
activity-log emit --kind decision --scope project:foo --summary "switched to Bun.fetch"

# query recent
activity-log query --hours 24

# auto-capture daemon (started via launchd/systemd)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.activity-mesh.watcher.plist
```

## Methodology

Built via **agent swarm research + super-plan iteration**:
- 8+ parallel agents on Claude Opus 4.7 surveyed: industry frameworks (Letta/Mem0/Zep/CrewAI), distributed event log patterns, Karpathy LLM Wiki principles, multi-runtime SDK integration, privacy/redaction tooling, clock consensus mechanics
- 5 super-plan iterations (v1 → v4) refined design
- 3 adversarial premortems caught 30+ edge cases before deploy
- All decisions documented with explicit acceptance criteria + premortem mitigations

See [METHODOLOGY.md](./METHODOLOGY.md) for full research bibliography.

## Architecture

5 read layers + 11 auto-capture sources + per-host JSONL + SQLite FTS5 + HTTP daemon. Full spec in [ARCHITECTURE.md](./ARCHITECTURE.md).

## Roadmap

- **v1** (this repo) = observability layer. Agents **know** what other agents did.
- **v2** (separate project) = action propagation. "Hermes installed X → Claude installs X too." Different class — needs orchestrator. Honestly scoped out.

See [ROADMAP.md](./ROADMAP.md) for detailed phases.

## License

MIT. See [LICENSE](./LICENSE).

## Acknowledgments

Heavy inspiration from:
- Andrej Karpathy — [LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), Sequoia Ascent 2026 keynote on agentic engineering
- Forrest Chang — [andrej-karpathy-skills CLAUDE.md](https://github.com/forrestchang/andrej-karpathy-skills) (60K stars, 4 behavioral principles)
- Mem0 — token-efficient retrieval algorithms
- Anthropic — Skills progressive disclosure pattern
