# CLAUDE.md patch — activity-mesh boundary rules

Append the section below to `~/.claude/CLAUDE.md` so every Claude Code session
knows where activity-mesh sits among Maxim's existing 5 memory layers.

The lookup order is the load-bearing rule: state → knowledge → history → recall → channel.
Activity-mesh is **HISTORY**, not state truth. Don't quote events as "current state" —
query MEMORY.md first.

---

## Memory canonical sources

| layer | role | when to read |
|---|---|---|
| **MEMORY.md** | state truth (current rules, prefs, infra facts) | "what IS the rule for X" |
| **Obsidian llm-wiki** | compoundable knowledge / decisions | "what's the pattern for X" |
| **activity-mesh** | raw event history | "WHEN did X happen / WHO did X" |
| **mempalace** | semantic recall projection | "things related to X" |
| **bridge channel memory** | isolated channel-agent state | channel-specific |

**Lookup order**: state → knowledge → history → recall → channel.

1. **State queries** ("what IS rule for X", "current preference for Y") → MEMORY.md
2. **Knowledge queries** ("what's pattern for X", "how do we handle Y") → wiki
3. **Timeline queries** ("WHEN did X happen", "WHO did Y") → activity-mesh
4. **Recall queries** ("things related to X") → mempalace
5. **Channel queries** (telegram-bridge-specific state) → bridge memory

**Activity-mesh is HISTORY, not STATE TRUTH.** Don't quote events as "current state" —
query MEMORY.md first; activity-mesh tells you when/who, not what-is.

You have access to the activity log via the `activity_recent` MCP tool or shell
`activity-log query`. Auto-context may already be injected via SessionStart digest
or UserPromptSubmit router; if not, query the tool — never claim "unknown" without
checking. Never paraphrase events as policy or current rule.
