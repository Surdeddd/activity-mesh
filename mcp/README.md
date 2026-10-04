# activity-mesh MCP server (Layer 4 — lazy tool)

Single-file Node 20+ MCP stdio server that exposes the activity log to any
MCP-compatible runtime — Claude Code, Codex, Hermes, OpenClaw, etc.

- **No npm dependencies** — Node stdlib only, a single file.
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
| `activity_digest` | grouped summary for a time window | `window?` (`today`, `yesterday`, `<N>h`, `<N>d`, `since:<ULID>`; default `today`), `group_by?` (`scope`/`agent`/`kind`) |

Digest windows: `today` and `yesterday` are local calendar days; `<N>h` and
`<N>d` are rolling windows (N is 1–99999, e.g. `48h`, `7d`, `30d`);
`since:<26-char ULID>` keeps events at or after that ULID's timestamp. Any
other value is an error that names the accepted forms — it used to fall back
to 24h silently.

> **Note** on `activity_search` and `activity_digest`: until the Go binary grows
> native `--search` / `--digest` flags, the MCP server fetches events via
> `activity-log query --format json` and post-processes in JS. Functionally
> identical from the agent's POV; binary upgrade is transparent.

## Resources (auto-discovery)

| URI template | description |
|---|---|
| `activity://recent/{scope}` | last events for a given scope as JSON |
| `activity://digest/{window}` | digest as markdown |

The `{scope}` / `{window}` value is percent-decoded, so
`activity://recent/project%3Afoo` reads the scope `project:foo`.

## Errors

- A tool that runs and fails — missing `activity-log` binary, a CLI exit other
  than 0, a bad argument such as an unknown digest window or a missing `query` —
  returns a normal result with `isError: true` and the message in
  `content[0].text`, so the model can read it and retry.
- Protocol problems are JSON-RPC errors: an unknown tool (`-32602`), a request
  that is not a JSON-RPC object (`-32600`), a line that is not JSON (`-32700`),
  an unknown method (`-32601`), an unsupported or malformed resource URI
  (`-32000`). None of them stops the server.

## Quick local test

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' | node mcp/server.mjs
```

Expected reply (the `[activity-mesh] starting …` line goes to stderr):

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false},"resources":{"subscribe":false,"listChanged":false}},"serverInfo":{"name":"activity-mesh","version":"<contents of the VERSION file>"}}}
```

`protocolVersion` echoes the client's when it is one of `2025-06-18`,
`2025-03-26`, `2024-11-05`, and falls back to `2025-06-18` otherwise.

The server also starts when launched through a symlink, which is how the
installed copy is reached: `node ~/.local/share/activity-mesh/dist/current/mcp/server.mjs`.

Run unit tests:

```bash
node --test mcp/server_test.mjs
```

## Install into runtimes

```bash
./mcp/install.sh --dry-run    # preview
./mcp/install.sh              # apply
./mcp/install.sh --help       # usage
```

Run it from a repo checkout, or from `~/.local/share/activity-mesh/dist/current/mcp/`
after `bootstrap.sh --local`. Release archives ship only `server.mjs`, not the
installer; after a release install register the server by hand through the
`dist/current` symlink, which survives upgrades:

```bash
claude mcp add activity-mesh --scope user -- node ~/.local/share/activity-mesh/dist/current/mcp/server.mjs
```

The installer registers `<checkout>/mcp/server.mjs` with:

- **Claude Code** — `claude mcp add activity-mesh --scope user -- <node> <server>`,
  which writes `~/.claude.json`; `<node>` is the absolute path of the `node`
  found on `PATH`, not the bare word `node` (Codex and Hermes get the same
  absolute path). Without the `claude` CLI on `PATH` it edits `~/.claude.json`
  with `jq` instead. `~/.claude/.mcp.json` and `mcpServers` in
  `~/.claude/settings.json` are not read by Claude Code, so nothing is written
  there.
- **Codex** — `~/.codex/config.toml`: appends `[mcp_servers.activity-mesh]`, or
  replaces the existing table in place (the server name, and `mcp_servers`
  itself, may each be bare, `"quoted"` or `'quoted'`), after saving
  `config.toml.bak-<timestamp>`. A replace resets the table's own keys:
  `command` and `args` are rewritten, and anything else you set directly inside
  `[mcp_servers.activity-mesh]` (`enabled = false`, a startup timeout, ...) is
  gone from the live file and only in the backup. Sub-tables such as
  `[mcp_servers.activity-mesh.env]`, every other table, and the comments and
  blank lines around them are kept. Replace and append both write a new file
  beside the target and rename it into place, so an interrupted run never
  leaves a half-written config, and a re-run that would change nothing writes
  nothing. When the server is already defined some other way (dotted keys such
  as `activity-mesh.command = ...` under `[mcp_servers]` or at the top of the
  file, or an inline table), a second `[mcp_servers.activity-mesh]` table would
  make the file invalid TOML, so the installer leaves the file alone, prints
  the line it found and the block to paste in by hand, still wires the other
  runtimes, and exits non-zero (also with `--dry-run`).
- **Hermes** — `~/.hermes/config.yaml`: appends a stdio MCP entry (same server
  as the other clients); skipped if Hermes is not installed, and printed for
  you to add by hand when the file already has a top-level `mcp_servers:`.
  The daemon serves `/health`, `/recent`, `/search`, `/digest`, `/push` and
  `/metrics` — it is not an MCP endpoint.
- **OpenClaw** — the installer prints an instruction; the project-local
  `mcp-bridge.mjs` must be edited by hand because path varies per project.

A config file that is a symlink (dotfiles setups) is written through to its
target and keeps its permissions. The Claude Code / Codex entries are
idempotent — re-running just overwrites the `activity-mesh` entry.
`--dry-run` only prints the plan.

`installers/uninstall.sh` removes the Claude Code and Codex registrations that
point into the `dist/` it deletes (for Codex the whole server: its table, and
every sub-table of it wherever they sit in the file), and tells you about a
Hermes entry and about anything else that still points into `dist/`.

## Binary resolution

`server.mjs` resolves the `activity-log` binary in this order:

1. `$ACTIVITY_LOG_BIN` env var (used by tests)
2. Repo-local `bin/activity-log-<os>-<arch>[.exe]` (works in dev / fresh clone)
3. `activity-log` on `PATH` (production install)

## Token budget

Measured with `tiktoken` (`cl100k_base`) on the `tools/list` response at
rc.7; the longer digest window list since then adds roughly 10 tokens:

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
