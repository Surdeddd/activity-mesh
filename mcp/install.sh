#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) echo "usage: install.sh [--dry-run]"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$REPO/mcp/server.mjs"
NODE_BIN="$(command -v node || true)"

if [[ ! -f "$SERVER" ]]; then echo "ERR: $SERVER not found" >&2; exit 1; fi
CFGEDIT="$REPO/installers/lib/cfgedit.sh"
if [[ ! -f "$CFGEDIT" ]]; then echo "ERR: missing helper $CFGEDIT" >&2; exit 1; fi
# shellcheck source=../installers/lib/cfgedit.sh
. "$CFGEDIT"
if [[ -z "$NODE_BIN" ]]; then echo "ERR: node not on PATH (need 20+)" >&2; exit 1; fi

say() { printf '%s\n' "$*"; }
plan() { if [[ $DRY_RUN -eq 1 ]]; then say "  [dry-run] $*"; else say "  $*"; fi; }

wire_claude() {
  # `claude mcp add` is the only supported way to register a user-scoped server:
  # it writes ~/.claude.json. The old target (~/.claude/.mcp.json, or
  # mcpServers in ~/.claude/settings.json) is never read by Claude Code, so the
  # installer used to report success while the tools never appeared.
  if command -v claude >/dev/null 2>&1; then
    say "Claude Code → claude mcp add (user scope → ~/.claude.json)"
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would run: claude mcp add activity-mesh --scope user -- $NODE_BIN $SERVER"
      return
    fi
    claude mcp remove activity-mesh --scope user >/dev/null 2>&1 || true
    if claude mcp add activity-mesh --scope user -- "$NODE_BIN" "$SERVER" >/dev/null 2>&1; then
      plan "registered activity-mesh via claude mcp add"
    else
      say "  WARN: 'claude mcp add' failed — register manually:"
      say "    claude mcp add activity-mesh --scope user -- $NODE_BIN $SERVER"
    fi
    return
  fi

  local target="$HOME/.claude.json"
  say "Claude Code → $target (claude CLI not on PATH)"
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would add mcpServers.activity-mesh to $target"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    say "  WARN: neither the claude CLI nor jq is available — register manually:"
    say "    claude mcp add activity-mesh --scope user -- $NODE_BIN $SERVER"
    return
  fi
  [[ -f "$target" ]] || echo '{}' > "$target"
  local tmp; tmp=$(mktemp)
  if jq --arg cmd "$NODE_BIN" --arg srv "$SERVER" \
       '.mcpServers["activity-mesh"] = {command:$cmd, args:[$srv]}' \
       "$target" > "$tmp" && write_through "$target" < "$tmp"; then
    rm -f "$tmp"
    plan "wrote activity-mesh entry via jq"
  else
    rm -f "$tmp"
    say "  WARN: could not patch $target — register manually:"
    say "    claude mcp add activity-mesh --scope user -- $NODE_BIN $SERVER"
  fi
}

codex_block() {
  printf '[mcp_servers.activity-mesh]\ncommand = "%s"\nargs = ["%s"]\n' "$NODE_BIN" "$SERVER"
}

codex_replace() {
  local cfg="$1" out="$2" line norm skipping=0 replaced=0
  : > "$out"
  while IFS= read -r line || [[ -n "$line" ]]; do
    norm="${line//[[:space:]]/}"
    norm="${norm%%#*}"
    case "$norm" in
      '[mcp_servers.activity-mesh]'|'[mcp_servers."activity-mesh"]'|"[mcp_servers.'activity-mesh']")
        if [[ $replaced -eq 0 ]]; then
          codex_block >> "$out"
          printf '\n' >> "$out"
          replaced=1
        fi
        skipping=1
        continue ;;
      '['*) skipping=0 ;;
    esac
    if [[ $skipping -eq 0 ]]; then printf '%s\n' "$line" >> "$out"; fi
  done < "$cfg"
  [[ $replaced -eq 1 ]]
}

wire_codex() {
  local cfg="$HOME/.codex/config.toml" has=0
  say "Codex → $cfg"
  if [[ -f "$cfg" ]] && codex_replace "$cfg" /dev/null; then has=1; fi
  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $has -eq 1 ]]; then
      plan "would replace the existing [mcp_servers.activity-mesh] block"
    else
      plan "would append [mcp_servers.activity-mesh] block"
    fi
    return
  fi
  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || : > "$cfg"
  if [[ $has -eq 1 ]]; then
    local tmp bak
    tmp="$(mktemp)"
    if ! codex_replace "$cfg" "$tmp"; then
      rm -f "$tmp"
      say "  WARN: could not rewrite $cfg — replace the [mcp_servers.activity-mesh] block by hand"
      return
    fi
    if cmp -s "$cfg" "$tmp"; then
      rm -f "$tmp"
      plan "already up to date"
      return
    fi
    bak="$cfg.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$cfg" "$bak"
    if write_through "$cfg" < "$tmp"; then
      plan "replaced the activity-mesh block (backup at $bak)"
    else
      say "  WARN: could not write $cfg (backup at $bak)"
    fi
    rm -f "$tmp"
    return
  fi
  { printf '\n'; codex_block; } >> "$cfg"
  plan "appended activity-mesh block"
}

wire_hermes() {
  local cfg="$HOME/.hermes/config.yaml"
  if [[ ! -f "$cfg" ]]; then
    say "Hermes → not installed (skip)"
    return
  fi
  say "Hermes → $cfg"
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would add mcp_servers.activity-mesh stdio entry"
    return
  fi
  if grep -q 'activity-mesh:' "$cfg" 2>/dev/null; then
    plan "already present, skipping"
    return
  fi
  # A blind append duplicates the top-level key when the config already has one,
  # and most YAML loaders take the last mapping — silently dropping every server
  # the user had configured.
  if grep -qE '^mcp_servers:' "$cfg" 2>/dev/null; then
    say "  WARN: $cfg already has a top-level 'mcp_servers:' — add this entry under it by hand:"
    say "    activity-mesh:"
    say "      transport: stdio"
    say "      command: $NODE_BIN"
    say "      args: [\"$SERVER\"]"
    return
  fi
  # stdio, like every other client: the daemon exposes /health, /recent,
  # /search, /digest, /push and /metrics — there is no /mcp route, so the HTTP
  # entry this used to write 404'd on every call.
  cat >> "$cfg" <<YAML

mcp_servers:
  activity-mesh:
    transport: stdio
    command: $NODE_BIN
    args: ["$SERVER"]
YAML
  plan "appended Hermes stdio entry"
}

note_openclaw() {
  say "OpenClaw → manual: edit ~/.openclaw/projects/<proj>/mcp-bridge.mjs"
  say "  add: { name: 'activity-mesh', command: '$NODE_BIN', args: ['$SERVER'] }"
}

main() {
  say "activity-mesh MCP installer (dry-run=$DRY_RUN)"
  say "  server: $SERVER"
  say "  node  : $NODE_BIN"
  say ""
  wire_claude
  wire_codex
  wire_hermes
  note_openclaw
  say ""
  say "done. restart your runtimes to pick up the new server."
}

main "$@"
