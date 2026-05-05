#!/usr/bin/env node
// activity-mesh MCP stdio server (Layer 4 lazy tool).
// Exposes 3 tools (recent/search/digest) + 2 resources to any MCP client.
// Node 20+ stdlib only. JSON-RPC 2.0 over stdin/stdout. Logs to stderr.
//
// Binary resolution: $ACTIVITY_LOG_BIN -> `activity-log` on PATH ->
// repo-local ./bin/activity-log-<os>-<arch>. Tests override via env.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import process from "node:process";
import os from "node:os";

const PROTOCOL = "2024-11-05";
const NAME = "activity-mesh";
const VERSION = "0.1.0";
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const log = (...a) => process.stderr.write(`[${NAME}] ${a.join(" ")}\n`);

function resolveBin() {
  if (process.env.ACTIVITY_LOG_BIN) return process.env.ACTIVITY_LOG_BIN;
  const arch = os.arch() === "arm64" ? "arm64" : "amd64";
  const platform = { darwin: "macos", linux: "linux", win32: "windows" }[process.platform] || "linux";
  const ext = process.platform === "win32" ? ".exe" : "";
  const local = resolve(ROOT, "bin", `activity-log-${platform}-${arch}${ext}`);
  if (existsSync(local)) return local;
  return "activity-log"; // PATH fallback
}

function run(bin, args, { timeoutMs = 8000 } = {}) {
  return new Promise((res, rej) => {
    const p = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    const t = setTimeout(() => { p.kill("SIGKILL"); rej(new Error(`timeout ${bin} ${args.join(" ")}`)); }, timeoutMs);
    p.stdout.on("data", d => out += d);
    p.stderr.on("data", d => err += d);
    p.on("error", e => { clearTimeout(t); rej(e); });
    p.on("close", code => { clearTimeout(t); code === 0 ? res(out) : rej(new Error(`exit ${code}: ${err.trim()}`)); });
  });
}

function parseJsonl(s) {
  return s.split("\n").map(l => l.trim()).filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

function hoursToSince(h) { return `${Math.max(1, Math.floor(h || 24))}h`; }

async function activityRecent({ scope, agent, host, hours = 24, limit = 20 } = {}) {
  const args = ["query", "--since", hoursToSince(hours), "--limit", String(limit), "--format", "json"];
  if (scope) args.push("--scope", scope);
  if (agent) args.push("--agent", agent);
  if (host) args.push("--host", host);
  return parseJsonl(await run(resolveBin(), args));
}

async function activitySearch({ query, since = "7d", until, limit = 20 } = {}) {
  if (!query) throw new Error("query required");
  const args = ["query", "--since", since, "--limit", "0", "--format", "json"];
  const events = parseJsonl(await run(resolveBin(), args));
  const q = query.toLowerCase();
  const cutoffEnd = until ? Date.parse(until) : null;
  const out = [];
  for (const e of events) {
    if (cutoffEnd && Date.parse(e.ts) > cutoffEnd) continue;
    const hay = `${e.summary || ""} ${e.scope || ""} ${e.agent || ""} ${(e.tags || []).join(" ")}`.toLowerCase();
    if (hay.includes(q)) out.push(e);
    if (out.length >= limit) break;
  }
  return out;
}

async function activityDigest({ window = "today", group_by = "scope" } = {}) {
  let since = "24h";
  if (window === "today") since = "24h";
  else if (window === "yesterday") since = "48h";
  else if (window === "7d") since = "7d";
  else if (window?.startsWith?.("since:")) since = "30d"; // ULID — fallback wide window
  const events = parseJsonl(await run(resolveBin(), ["query", "--since", since, "--limit", "0", "--format", "json"]));
  const groups = {};
  for (const e of events) {
    const key = e[group_by] || "(none)";
    (groups[key] ||= []).push(e);
  }
  const lines = [`# Digest: ${window} (group_by=${group_by}, total=${events.length})`, ""];
  for (const [k, evs] of Object.entries(groups).sort((a, b) => b[1].length - a[1].length)) {
    lines.push(`## ${k} (${evs.length})`);
    for (const e of evs.slice(0, 8)) lines.push(`- ${e.ts} [${e.host}/${e.agent}] ${e.kind}: ${e.summary}`);
    if (evs.length > 8) lines.push(`- ... +${evs.length - 8} more`);
    lines.push("");
  }
  return { window, group_by, total: events.length, groups: Object.fromEntries(Object.entries(groups).map(([k, v]) => [k, v.length])), markdown: lines.join("\n") };
}

const TOOLS = [
  { name: "activity_recent",
    description: "Get N most recent activity events, optionally filtered by scope/agent/host/time. Use when user asks 'что было', 'recent', or needs timeline context.",
    inputSchema: { type: "object", properties: { scope: { type: "string" }, agent: { type: "string" }, host: { type: "string" }, hours: { type: "number", default: 24 }, limit: { type: "number", default: 20 } } } },
  { name: "activity_search",
    description: "Full-text search activity log with FTS5. Use when user mentions specific keyword/project not in scope vocabulary.",
    inputSchema: { type: "object", required: ["query"], properties: { query: { type: "string" }, since: { type: "string", default: "7d" }, until: { type: "string" }, limit: { type: "number", default: 20 } } } },
  { name: "activity_digest",
    description: "Get pre-summarized digest of activity for a time window. Use for 'статус', 'что было сегодня', weekly review.",
    inputSchema: { type: "object", properties: { window: { type: "string", enum: ["today", "yesterday", "7d"], default: "today" }, group_by: { type: "string", enum: ["scope", "agent", "kind"], default: "scope" } } } },
];

const RESOURCE_TEMPLATES = [
  { uriTemplate: "activity://recent/{scope}", name: "Recent events by scope", mimeType: "application/json" },
  { uriTemplate: "activity://digest/{window}", name: "Digest for time window", mimeType: "text/markdown" },
];

async function dispatchTool(name, args) {
  switch (name) {
    case "activity_recent": return activityRecent(args || {});
    case "activity_search": return activitySearch(args || {});
    case "activity_digest": return activityDigest(args || {});
    default: throw new Error(`unknown tool: ${name}`);
  }
}

async function readResource(uri) {
  const m = uri.match(/^activity:\/\/(recent|digest)\/(.+)$/);
  if (!m) throw new Error(`unsupported uri: ${uri}`);
  const [, kind, val] = m;
  if (kind === "recent") return { uri, mimeType: "application/json", text: JSON.stringify(await activityRecent({ scope: val }), null, 2) };
  return { uri, mimeType: "text/markdown", text: (await activityDigest({ window: val })).markdown };
}

async function handle(req) {
  const { id, method, params } = req;
  try {
    if (method === "initialize") return { jsonrpc: "2.0", id, result: { protocolVersion: PROTOCOL, capabilities: { tools: {}, resources: { subscribe: false, listChanged: false } }, serverInfo: { name: NAME, version: VERSION } } };
    if (method === "initialized" || method === "notifications/initialized") return null;
    if (method === "tools/list") return { jsonrpc: "2.0", id, result: { tools: TOOLS } };
    if (method === "tools/call") {
      const data = await dispatchTool(params?.name, params?.arguments);
      return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: typeof data === "string" ? data : JSON.stringify(data, null, 2) }], isError: false } };
    }
    if (method === "resources/list") return { jsonrpc: "2.0", id, result: { resources: [], resourceTemplates: RESOURCE_TEMPLATES } };
    if (method === "resources/templates/list") return { jsonrpc: "2.0", id, result: { resourceTemplates: RESOURCE_TEMPLATES } };
    if (method === "resources/read") return { jsonrpc: "2.0", id, result: { contents: [await readResource(params?.uri)] } };
    if (method === "ping") return { jsonrpc: "2.0", id, result: {} };
    return { jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${method}` } };
  } catch (e) {
    log("err:", method, e.message);
    return { jsonrpc: "2.0", id, error: { code: -32000, message: e.message } };
  }
}

function send(msg) { if (msg) process.stdout.write(JSON.stringify(msg) + "\n"); }

async function main() {
  log(`starting (bin=${resolveBin()})`);
  const rl = createInterface({ input: process.stdin, terminal: false });
  for await (const line of rl) {
    const t = line.trim();
    if (!t) continue;
    let req;
    try { req = JSON.parse(t); } catch (e) { send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }); continue; }
    send(await handle(req));
  }
}

const entry = fileURLToPath(import.meta.url);
if (entry === process.argv[1] || entry === resolve(process.argv[1] || "")) main().catch(e => { log("fatal:", e.stack); process.exit(1); });

export { resolveBin, run, parseJsonl, activityRecent, activitySearch, activityDigest, TOOLS, RESOURCE_TEMPLATES, handle };
