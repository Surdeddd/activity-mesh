// Native node:test runner. Run: node --test mcp/server_test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SERVER = resolve(HERE, "server.mjs");

// Minimal mock binary that pretends to be `activity-log query --format json`.
// Emits one JSONL event per call so the server can parse it.
function makeMockBin(scenario = "ok") {
  const dir = mkdtempSync(join(tmpdir(), "amesh-mock-"));
  const bin = join(dir, "activity-log");
  const events = [
    { v: 1, id: "01HRX1", ts: "2026-05-04T10:00:00.000000Z", host: "macbook", agent: "claude-mac", kind: "decision", scope: "project:foo", summary: "switched to Bun.fetch", tags: ["bun"] },
    { v: 1, id: "01HRX2", ts: "2026-05-04T11:00:00.000000Z", host: "macbook", agent: "hermes", kind: "task", scope: "project:bar", summary: "deployed billing-proxy" },
  ];
  let body;
  if (scenario === "fail") {
    body = `#!/bin/sh\necho "boom" 1>&2\nexit 2\n`;
  } else {
    body = `#!/bin/sh\ncat <<'JSON'\n${events.map(e => JSON.stringify(e)).join("\n")}\nJSON\n`;
  }
  writeFileSync(bin, body);
  chmodSync(bin, 0o755);
  return bin;
}

function rpcCall(env, ...messages) {
  return new Promise((res, rej) => {
    const p = spawn(process.execPath, [SERVER], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", d => out += d);
    const errChunks = [];
    p.stderr.on("data", d => errChunks.push(d.toString()));
    p.on("error", rej);
    p.on("close", () => {
      const lines = out.split("\n").filter(Boolean).map(l => JSON.parse(l));
      res({ replies: lines, stderr: errChunks.join("") });
    });
    for (const m of messages) p.stdin.write(JSON.stringify(m) + "\n");
    p.stdin.end();
  });
}

test("initialize handshake", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {}, clientInfo: { name: "t", version: "1" } } });
  const r = replies[0];
  assert.equal(r.jsonrpc, "2.0");
  assert.equal(r.id, 1);
  assert.equal(r.result.serverInfo.name, "activity-mesh");
  assert.equal(r.result.protocolVersion, "2024-11-05");
  assert.ok(r.result.capabilities.tools);
});

test("tools/list returns 3 tools", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/list" });
  const list = replies.find(r => r.id === 2);
  assert.equal(list.result.tools.length, 3);
  const names = list.result.tools.map(t => t.name).sort();
  assert.deepEqual(names, ["activity_digest", "activity_recent", "activity_search"]);
  for (const t of list.result.tools) {
    assert.ok(t.description.length > 30, `desc too short for ${t.name}`);
    assert.equal(t.inputSchema.type, "object");
  }
});

test("tools/call activity_recent shells out to mock", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_recent", arguments: { hours: 24, limit: 5 } } });
  const r = replies.find(x => x.id === 2);
  assert.equal(r.result.isError, false);
  const payload = JSON.parse(r.result.content[0].text);
  assert.equal(payload.length, 2);
  assert.equal(payload[0].id, "01HRX1");
});

test("tools/call activity_search filters by query", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_search", arguments: { query: "billing" } } });
  const r = replies.find(x => x.id === 2);
  const payload = JSON.parse(r.result.content[0].text);
  assert.equal(payload.length, 1);
  assert.match(payload[0].summary, /billing/);
});

test("tools/call activity_digest groups by scope", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_digest", arguments: { window: "today", group_by: "scope" } } });
  const r = replies.find(x => x.id === 2);
  const payload = JSON.parse(r.result.content[0].text);
  assert.equal(payload.total, 2);
  assert.ok(payload.markdown.includes("project:foo"));
  assert.ok(payload.markdown.includes("project:bar"));
});

test("tools/call invalid name returns error", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "nope", arguments: {} } });
  const r = replies.find(x => x.id === 2);
  assert.ok(r.error);
  assert.match(r.error.message, /unknown tool/);
});

test("binary not found surfaces as JSON-RPC error", async () => {
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: "/nonexistent/binary-xyz" },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_recent", arguments: {} } });
  const r = replies.find(x => x.id === 2);
  assert.ok(r.error);
  assert.equal(r.error.code, -32000);
});

test("activity_search requires query argument", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_search", arguments: {} } });
  const r = replies.find(x => x.id === 2);
  assert.ok(r.error);
  assert.match(r.error.message, /query required/);
});

test("resources/list returns templates", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "resources/list" });
  const r = replies.find(x => x.id === 2);
  assert.equal(r.result.resourceTemplates.length, 2);
  assert.match(r.result.resourceTemplates[0].uriTemplate, /^activity:\/\//);
});

test("unknown method returns -32601", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "bogus/method" });
  const r = replies.find(x => x.id === 2);
  assert.equal(r.error.code, -32601);
});
