#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$REPO/mcp/server.mjs"
NODE_BIN="$(command -v node || true)"

if [[ ! -f "$SERVER" ]]; then echo "ERR: $SERVER not found" >&2; exit 1; fi
if [[ -z "$NODE_BIN" ]]; then echo "ERR: node not on PATH (need 20+)" >&2; exit 1; fi

say() { printf '%s\n' "$*"; }
plan() { if [[ $DRY_RUN -eq 1 ]]; then say "  [dry-run] $*"; else say "  $*"; fi; }

wire_claude() {
  local mcp_json="$HOME/.claude/.mcp.json"
  local settings="$HOME/.claude/settings.json"
  local target=""
  if [[ -f "$mcp_json" ]]; then target="$mcp_json"
  elif [[ -f "$settings" ]]; then target="$settings"
  else target="$mcp_json"; fi
  say "Claude Code → $target"
  local entry
  entry=$(cat <<JSON
{
  "command": "$NODE_BIN",
  "args": ["$SERVER"]
}
JSON
)
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would add mcpServers.activity-mesh = $entry"
    return
  fi
  mkdir -p "$(dirname "$target")"
  if [[ ! -f "$target" ]]; then echo '{"mcpServers":{}}' > "$target"; fi
  if command -v jq >/dev/null 2>&1; then
    local tmp; tmp=$(mktemp)
    jq --arg cmd "$NODE_BIN" --arg srv "$SERVER" \
       '.mcpServers["activity-mesh"] = {command:$cmd, args:[$srv]}' \
       "$target" > "$tmp" && mv "$tmp" "$target"
    plan "wrote activity-mesh entry via jq"
  else
    say "  WARN: jq missing — please add manually to $target:"
    say "    \"activity-mesh\": $entry"
  fi
}

wire_codex() {
  local cfg="$HOME/.codex/config.toml"
  say "Codex → $cfg"
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would append [mcp_servers.activity-mesh] block"
    return
  fi
  mkdir -p "$(dirname "$cfg")"
  touch "$cfg"
  if grep -q '^\[mcp_servers\.activity-mesh\]' "$cfg" 2>/dev/null; then
    plan "already present, skipping"
    return
  fi
  cat >> "$cfg" <<TOML

[mcp_servers.activity-mesh]
command = "$NODE_BIN"
args = ["$SERVER"]
TOML
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
    plan "would add mcp_servers.activity-mesh.url = http://localhost:7459/mcp"
    return
  fi
  if grep -q 'activity-mesh:' "$cfg" 2>/dev/null; then
    plan "already present, skipping"
    return
  fi
  cat >> "$cfg" <<YAML

mcp_servers:
  activity-mesh:
    transport: http
    url: http://localhost:7459/mcp
    note: Hermes uses the HTTP daemon (P3) instead of stdio so the binary stays single-process.
YAML
  plan "appended Hermes HTTP entry (assumes daemon on :7459)"
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
