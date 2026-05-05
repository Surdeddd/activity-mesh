# activity-mesh — conflict rules vs Maxim's existing 5 memory layers

When activity-mesh lands alongside an established memory stack (MEMORY.md,
llm-wiki, mempalace, bridge memory, OpenClaw shared/KB, Hermes SOUL), every
event has a potential overlap with another layer. This file is the explicit
arbitration table for those overlaps. Follow these rules when designing new
writers, hooks, or readers; ignore them and you'll re-introduce drift.

## Core invariants

1. **activity-mesh is HISTORY, not STATE TRUTH.**
   Events answer *when* and *who*. They do not encode *what is currently
   true*. State truth is MEMORY.md.

2. **No layer reads from another via parsing.**
   Each layer queries its canonical store. Cross-layer awareness is by
   reference (`ref: wiki://...` in an event), not by quote.

3. **One write per logical action, per layer.**
   A "session ended" produces one wiki inbox drop AND one activity event,
   never two of either. Multi-layer writes are intentional and orthogonal.

## Specific overlaps

### llm-wiki/log.md  vs  activity-mesh events

| concern | wiki/log.md | activity-mesh |
|---|---|---|
| writer | wiki **compiler only** (one process, one machine) | every agent (claude-mac, hermes, openclaw bots, daemons) |
| frequency | once per compile cycle | per logical event |
| purpose | audit of what the compiler did | timeline of what happened in the world |
| retention | wiki retention policy | activity retention policy (per-host JSONL) |

**Rule**: do not duplicate compiler audit lines into activity-mesh.
Compile events that *should* surface in activity-mesh use `kind: compile`
and `scope: activity-mesh` (or the relevant scope), not a wiki/log.md mirror.

### mempalace timeline  vs  activity-mesh

| concern | mempalace | activity-mesh |
|---|---|---|
| shape | semantic graph; entities, drawers, wings | append-only chronological JSONL |
| query | "things related to X" | "events at time T involving Y" |
| projection direction | mempalace can ingest activity events (later) | activity-mesh never ingests mempalace |
| temporal grain | episode-level, recall-friendly | event-level, audit-friendly |

**Rule**: mempalace is a *projection* of underlying signals, not a peer.
A future indexer may copy activity events into mempalace; activity-mesh
must not query mempalace for "current state".

### bridge memory  vs  activity-mesh from telegram

| concern | bridge memory | activity-mesh |
|---|---|---|
| owner | the channels-plugin Claude instance | every agent |
| scope | conversational + canonical bridge persona | global cross-machine |
| direction | bridge **reads** activity events to answer Maxim's "что я сегодня делал" | bridge does NOT emit per-message activity events |
| isolation | isolated state dir per channel | shared sync dir |

**Rule**: bridge memory is read-mostly against activity-mesh. The bridge
agent does not emit a per-message activity event — that would create
massive duplication (every chat ack = one event). It MAY emit events for
specific cross-cutting actions (skill promote, draft approve), with
`scope: bridge-telegram` and `kind: decision`/`task`.

### OpenClaw shared/KB  vs  activity-mesh

| concern | shared/KB | activity-mesh |
|---|---|---|
| writer | OpenClaw orchestrator + bots | same bots, but for events |
| shape | structured docs (decisions/, sops/, plans/) | append-only events |
| sync | mac-mini local + git-sync | Syncthing per-host JSONL |

**Rule**: KB documents and activity events are orthogonal. A new SOP file
written into shared/KB SHOULD trigger an activity event with
`kind: decision, scope: openclaw, ref: file://...`, but the SOP body lives
ONLY in shared/KB.

### MEMORY.md  vs  activity-mesh

| concern | MEMORY.md | activity-mesh |
|---|---|---|
| nature | state truth, current rules | history, what happened |
| ownership | Maxim + Claude + auto-memory hooks | every emitter |
| read by | every Claude session at startup | on-demand, MCP tool |

**Rule**: a state change (e.g. a feature flag flipped) MUST update
MEMORY.md AND emit an activity event with `kind: decision`. Updating
only one creates drift. The lookup-order in CLAUDE.md guarantees readers
treat MEMORY.md as authoritative.

## Decision matrix: where do I write?

| signal | write to MEMORY.md? | write to wiki? | emit activity event? |
|---|---|---|---|
| "I changed a permanent rule / preference" | yes | yes (compoundable) | yes (`kind: decision`) |
| "I learned a pattern, durable insight" | optional pointer | yes | optional (`kind: note`) |
| "Daemon X started/stopped, deploy happened" | no | no | yes (`kind: status` / `ops/deploy`) |
| "Skill installed / dependency upgraded" | no (unless rule-affecting) | maybe (decision rationale) | yes (`kind: install`) |
| "Bridge replied to a Telegram message" | no | no | no (would flood) |
| "Bot escalated to oncall" | no | no | yes (`kind: ops/incident`) |
| "Synthetic health check passed" | no | no | yes (`kind: canary`) |
| "Wiki compiler ran" | no | no | yes (`kind: compile`) |

## Open questions / future work

- A unified read-projection (mempalace timeline) that ingests activity
  events on a schedule. Until then, activity-mesh has its own MCP tool
  (`activity_recent`).
- Writer self-emission for hermes / openclaw bots (currently only
  claude-mac via session-end-flush.sh + manual CLI).
- Per-host retention policy (currently unbounded JSONL growth).
