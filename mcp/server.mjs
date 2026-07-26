#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import process from "node:process";
import os from "node:os";

const SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const PREFERRED_PROTOCOL = SUPPORTED_PROTOCOLS[0];
const NAME = "activity-mesh";
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function readVersion() {
  try {
    return readFileSync(resolve(ROOT, "VERSION"), "utf8").trim() || "dev";
  } catch {
    return "dev";
  }
}
const VERSION = readVersion();

const log = (...a) => process.stderr.write(`[${NAME}] ${a.join(" ")}\n`);

function resolveBin() {
  if (process.env.ACTIVITY_LOG_BIN) return process.env.ACTIVITY_LOG_BIN;
  const arch = os.arch() === "arm64" ? "arm64" : "amd64";
  const platform = { darwin: "darwin", linux: "linux", win32: "windows" }[process.platform] || "linux";
  const ext = process.platform === "win32" ? ".exe" : "";
  const local = resolve(ROOT, "bin", `activity-log-${platform}-${arch}${ext}`);
  if (existsSync(local)) return local;
  return "activity-log";
}

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

function ulidToMs(u) {
  if (typeof u !== "string" || u.length !== 26) return null;
  let ms = 0;
  for (const ch of u.slice(0, 10).toUpperCase()) {
    const v = CROCKFORD.indexOf(ch);
    if (v < 0) return null;
    ms = ms * 32 + v;
  }
  return ms;
}

function run(bin, args, { timeoutMs = 8000 } = {}) {
  return new Promise((res, rej) => {
    const p = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    // Collect Buffers and decode once: `out += d` decodes each chunk on its own,
    // so a multi-byte character split across a chunk boundary turns into U+FFFD
    // — Cyrillic summaries are long enough to hit this routinely.
    const outChunks = [], errChunks = [];
    const t = setTimeout(() => { p.kill("SIGKILL"); rej(new Error(`timeout ${bin} ${args.join(" ")}`)); }, timeoutMs);
    p.stdout.on("data", d => outChunks.push(d));
    p.stderr.on("data", d => errChunks.push(d));
    p.on("error", e => { clearTimeout(t); rej(e); });
    p.on("close", code => {
      clearTimeout(t);
      const out = Buffer.concat(outChunks).toString("utf8");
      if (code === 0) return res(out);
      rej(new Error(`exit ${code}: ${Buffer.concat(errChunks).toString("utf8").trim()}`));
    });
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
  events.reverse();
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

// Local-day bounds. "today" and "yesterday" are what the user sees on their own
// clock: computing them in UTC files the first hours of a local day (or the last,
// west of Greenwich) into the wrong bucket for every non-UTC user.
function dayBounds(daysAgo) {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo);
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo + 1);
  return [start.getTime(), end.getTime()];
}

async function activityDigest({ window = "today", group_by = "scope" } = {}) {
  let since = "24h", lo = null, hi = null;
  if (window === "today") { since = "24h"; [lo, hi] = dayBounds(0); }
  else if (window === "yesterday") { since = "48h"; [lo, hi] = dayBounds(1); }
  else if (window === "7d") since = "7d";
  else if (window?.startsWith?.("since:")) {
    const ms = ulidToMs(window.slice(6));
    if (ms === null) throw new Error("since: window requires a 26-char ULID");
    const ageH = Math.max(1, Math.ceil((Date.now() - ms) / 3600000));
    since = `${ageH}h`;
    lo = ms;
    hi = Date.now() + 86400000;
  }
  let events = parseJsonl(await run(resolveBin(), ["query", "--since", since, "--limit", "0", "--format", "json"]));
  if (lo !== null) {
    events = events.filter(e => { const t = Date.parse(e.ts); return t >= lo && t < hi; });
  }
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

const READONLY = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const TOOLS = [
  { name: "activity_recent",
    description: "Get N most recent activity events, optionally filtered by scope/agent/host/time. Use when user asks 'что было', 'recent', or needs timeline context.",
    inputSchema: { type: "object", properties: { scope: { type: "string" }, agent: { type: "string" }, host: { type: "string" }, hours: { type: "number", default: 24 }, limit: { type: "number", default: 20 } } },
    annotations: { title: "Recent activity", ...READONLY } },
  { name: "activity_search",
    description: "Case-insensitive substring search over recent activity events (summary/scope/agent/tags), newest first. Local-first: scans the JSONL shards via the CLI, not the daemon's FTS index. Widen `since` to search further back.",
    inputSchema: { type: "object", required: ["query"], properties: { query: { type: "string" }, since: { type: "string", default: "7d" }, until: { type: "string" }, limit: { type: "number", default: 20 } } },
    annotations: { title: "Search activity", ...READONLY } },
  { name: "activity_digest",
    description: "Get pre-summarized digest of activity for a time window: today | yesterday | 7d | since:<26-char ULID> (events at or after that ULID's timestamp).",
    inputSchema: { type: "object", properties: { window: { type: "string", default: "today", description: "today | yesterday | 7d | since:<ULID>" }, group_by: { type: "string", enum: ["scope", "agent", "kind"], default: "scope" } } },
    annotations: { title: "Activity digest", ...READONLY } },
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
    if (method === "initialize") {
      const want = params?.protocolVersion;
      const proto = SUPPORTED_PROTOCOLS.includes(want) ? want : PREFERRED_PROTOCOL;
      return { jsonrpc: "2.0", id, result: { protocolVersion: proto, capabilities: { tools: { listChanged: false }, resources: { subscribe: false, listChanged: false } }, serverInfo: { name: NAME, version: VERSION } } };
    }
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
    // A JSON-RPC notification has no id and MUST NOT be answered; replying with
    // `id: undefined` also produces a response object missing a required field.
    if (id === undefined || id === null) return null;
    return { jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${method}` } };
  } catch (e) {
    log("err:", method, e.message);
    if (id === undefined || id === null) return null;
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
