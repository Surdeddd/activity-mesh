# activity-mesh MCP server (Layer 4 — lazy tool)

Single-file Node 20+ MCP stdio server that exposes the activity log to any
MCP-compatible runtime — Claude Code, Codex, Hermes, OpenClaw, etc.

- **No npm dependencies** — Node stdlib only, ~170 LOC.
- **Lazy** — agent context cost is ~250 tokens for the 3 tool schemas; loaded only
  when the runtime advertises this MCP server (lazy via `disable-model-invocation`
  or per-prompt activation).
- **Shells out** to the existing `activity-log` Go binary; never reimplements
  query / redaction logic.

## Tools

| name | purpose | args |
|---|---|---|
| `activity_recent` | N most recent events, scoped/agent/host/time filtered | `scope?`, `agent?`, `host?`, `hours?` (default 24), `limit?` (20) |
| `activity_search` | substring search across summary/scope/agent/tags | `query` (required), `since?` (7d), `until?`, `limit?` |
| `activity_digest` | grouped summary for a time window | `window?` (`today`/`yesterday`/`7d`), `group_by?` (`scope`/`agent`/`kind`) |

> **Note** on `activity_search` and `activity_digest`: until the Go binary grows
> native `--search` / `--digest` flags, the MCP server fetches events via
> `activity-log query --format json` and post-processes in JS. Functionally
> identical from the agent's POV; binary upgrade is transparent.

## Resources (auto-discovery)

| URI template | description |
|---|---|
| `activity://recent/{scope}` | last events for a given scope as JSON |
| `activity://digest/{window}` | digest as markdown |

## Quick local test

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' | node mcp/server.mjs
```

Expected reply:

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{"subscribe":false,"listChanged":false}},"serverInfo":{"name":"activity-mesh","version":"0.1.0"}}}
```

Run unit tests:

```bash
node --test mcp/server_test.mjs
```

## Install into runtimes

```bash
./mcp/install.sh --dry-run    # preview
./mcp/install.sh              # apply
```

The installer writes:

- `~/.claude/.mcp.json` (or `~/.claude/settings.json` if it exists) — adds
  `mcpServers["activity-mesh"]`
- `~/.codex/config.toml` — appends `[mcp_servers.activity-mesh]`
- `~/.hermes/config.yaml` — appends HTTP MCP entry pointing at the P3 daemon
  (`http://localhost:7459/mcp`); skipped if Hermes is not installed
- For **OpenClaw**, the installer prints an instruction; the project-local
  `mcp-bridge.mjs` must be edited by hand because path varies per project.

The Claude Code / Codex blocks are idempotent — re-running just overwrites the
`activity-mesh` entry. `--dry-run` only prints the plan.

## Binary resolution

`server.mjs` resolves the `activity-log` binary in this order:

1. `$ACTIVITY_LOG_BIN` env var (used by tests)
2. Repo-local `bin/activity-log-<os>-<arch>[.exe]` (works in dev / fresh clone)
3. `activity-log` on `PATH` (production install)

## Token budget

Measured with `tiktoken` (`cl100k_base`) on the actual `tools/list` response:

```
TOTAL: 335 tokens
  activity_recent: 116 toks (description 34)
  activity_search: 102 toks (description 22)
  activity_digest: 115 toks (description 33)
```

Resource templates add ~30. Loaded lazily — when the agent actually calls a
tool, the response payload is the dominant cost (typically 500–1500 tokens for
a recent/digest call), which matches the L4 budget in `ARCHITECTURE.md`
(`+1500 on call`).

## Architecture link

This is **Layer 4** in the 5-layer read stack from `ARCHITECTURE.md`. L1 is the
schema in `CLAUDE.md`/`AGENTS.md`, L2 is the SessionStart digest hook, L3 is the
invisible UserPromptSubmit router (highest leverage), L4 is this MCP server for
explicit drill-down, L5 is Telegram push for P0/P1 incidents.

If you find yourself reaching for L4 a lot for queries that L3 should be
catching automatically, file an issue — that's a regex tuning bug, not an MCP
usage problem.
