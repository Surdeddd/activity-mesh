# CLAUDE.md patch — activity-mesh integration with 5 memory layers

This file is the *exact* text the install.sh script writes into Maxim's
existing `~/.claude/CLAUDE.md`. Maxim's CLAUDE.md already contains a
"Memory canonical sources" section (4 rows). The installer:

1. Adds the missing **operational history** row to the table, between
   "compoundable patterns" and "semantic search index".
2. Adds (or updates) the explicit **Lookup order** subsection.
3. Adds a closing rule: **activity-mesh = HISTORY, not STATE TRUTH**.
4. Adds the auto-context note about the `activity_recent` MCP tool.

The installer is idempotent — running it twice produces the same file.

---

## Memory canonical sources (не путать)

| что | где | роль |
|---|---|---|
| **state truth** (active rules, current preferences, infrastructure facts) | `~/.claude/projects/-Users-maksimkravcov/memory/MEMORY.md` + .md files | always-on в каждой сессии. Single source — если правило поменялось, апдейтим **тут** |
| **compoundable patterns / decisions** (durable знания) | `~/Obsidian/llm-wiki/` — schema canonical: `~/Obsidian/llm-wiki/AGENTS.md` | wiki growth via inbox→compile flow |
| **operational history** (что-кто-когда-сделал, cross-machine) | **activity-mesh**: `~/Sync/activity/events-<host>.jsonl` + daemon на `:7459` | timeline queries, cross-machine awareness. **NOT state truth** — это history |
| **semantic search index** (projection обоих выше) | MemPalace (`mempalace:*` MCP, drawers/wings/rooms) | когда не помню как искать в MEMORY.md по теме |
| **bridge-агента память** (изолирована) | `~/.claude/channels/telegram/memory/` | у канального инстанса своя |

**Lookup order**:

1. **State queries** ("что IS правило для X / current preference for Y") → `MEMORY.md`
2. **Knowledge queries** ("какой pattern для X / how do we handle Y") → wiki
3. **Timeline queries** ("WHEN произошло X / WHO сделал X") → **activity-mesh** (`activity_recent` MCP / `activity-log query` CLI)
4. **Recall queries** ("вещи related to X") → mempalace
5. **Channel queries** (bridge-specific state) → bridge memory

**Rule**: activity-mesh = HISTORY, не STATE TRUTH. Не цитировать activity events as "current state" — query MEMORY первым. Activity events answer **WHEN/WHO**, MEMORY answers **WHAT IS**.

`activity_recent` MCP tool auto-loaded; auto-context инжектится через UserPromptSubmit hook (see `~/.claude/hooks/user-prompt-router.sh`). Если не injected — call the tool. Никогда не "не знаю" про operational history если демон жив.

<!-- activity-mesh:integration:end -->
