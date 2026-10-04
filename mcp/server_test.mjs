import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync, mkdirSync, readFileSync, symlinkSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SERVER = resolve(HERE, "server.mjs");

function makeMockBin(scenario = "ok", tsIso, tsIso2, eventList) {
  const dir = mkdtempSync(join(tmpdir(), "amesh-mock-"));
  const bin = join(dir, "activity-log");
  const t1 = tsIso || "2026-05-04T10:00:00.000000Z";
  const t2 = tsIso2 || tsIso || "2026-05-04T11:00:00.000000Z";
  const events = eventList || [
    { v: 1, id: "01HRX1", ts: t1, host: "macbook", agent: "claude-mac", kind: "decision", scope: "project:foo", summary: "switched to Bun.fetch", tags: ["bun"] },
    { v: 1, id: "01HRX2", ts: t2, host: "macbook", agent: "hermes", kind: "task", scope: "project:bar", summary: "deployed billing-proxy" },
  ];
  const logArgs = `echo "$@" >> "${dir}/args.log"\n`;
  let body;
  if (scenario === "fail") {
    body = `#!/bin/sh\n${logArgs}echo "boom" 1>&2\nexit 2\n`;
  } else {
    body = `#!/bin/sh\n${logArgs}cat <<'JSON'\n${events.map(e => JSON.stringify(e)).join("\n")}\nJSON\n`;
  }
  writeFileSync(bin, body);
  chmodSync(bin, 0o755);
  return bin;
}

function cliCalls(bin) {
  try {
    return readFileSync(join(dirname(bin), "args.log"), "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

const initMsg = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} };
const callMsg = (id, name, args) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });

// `today`/`yesterday` are local-day windows (a UTC day boundary misfiles the
// first hours of the local day for every non-UTC user), so fixtures must be
// anchored to local noon rather than to a UTC calendar date.
function localNoonIso(daysAgo = 0) {
  const d = new Date();
  d.setDate(d.getDate() - daysAgo);
  d.setHours(12, 0, 0, 0);
  return d.toISOString();
}

function rpcCallAt(server, env, ...messages) {
  return new Promise((res, rej) => {
    const p = spawn(process.execPath, [server], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", d => out += d);
    const errChunks = [];
    p.stderr.on("data", d => errChunks.push(d.toString()));
    p.on("error", rej);
    p.on("close", code => {
      const lines = out.split("\n").filter(Boolean).map(l => JSON.parse(l));
      res({ replies: lines, stderr: errChunks.join(""), code });
    });
    for (const m of messages) p.stdin.write((typeof m === "string" ? m : JSON.stringify(m)) + "\n");
    p.stdin.end();
  });
}

const rpcCall = (env, ...messages) => rpcCallAt(SERVER, env, ...messages);

test("initialize handshake", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {}, clientInfo: { name: "t", version: "1" } } });
  const r = replies[0];
  assert.equal(r.jsonrpc, "2.0");
  assert.equal(r.id, 1);
  assert.equal(r.result.serverInfo.name, "activity-mesh");
  assert.equal(r.result.protocolVersion, "2025-06-18");
  assert.ok(r.result.capabilities.tools);
});

test("initialize negotiates the client's protocol version when supported", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05" } });
  assert.equal(replies[0].result.protocolVersion, "2024-11-05");
});

test("tools carry read-only annotations", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/list" });
  const list = replies.find(r => r.id === 2);
  for (const t of list.result.tools) {
    assert.equal(t.annotations?.readOnlyHint, true, `${t.name} must be read-only`);
  }
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
  const today = localNoonIso();
  const bin = makeMockBin("ok", today);
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_digest", arguments: { window: "today", group_by: "scope" } } });
  const r = replies.find(x => x.id === 2);
  const payload = JSON.parse(r.result.content[0].text);
  assert.equal(payload.total, 2);
  assert.ok(payload.markdown.includes("project:foo"));
  assert.ok(payload.markdown.includes("project:bar"));
});

test("tools/call activity_digest yesterday excludes today", async () => {
  const today = localNoonIso();
  const bin = makeMockBin("ok", today);
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_digest", arguments: { window: "yesterday" } } });
  const payload = JSON.parse(replies.find(x => x.id === 2).result.content[0].text);
  assert.equal(payload.total, 0, "today's events must not appear under yesterday");
});

test("tools/call invalid name returns error", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "nope", arguments: {} } });
  const r = replies.find(x => x.id === 2);
  assert.ok(r.error);
  assert.equal(r.error.code, -32602);
  assert.match(r.error.message, /unknown tool/);
  assert.deepEqual(cliCalls(bin), [], "an unknown tool must not reach the CLI");
});

test("binary not found surfaces as a tool error result", async () => {
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: "/nonexistent/binary-xyz" },
    initMsg, callMsg(2, "activity_recent", {}));
  const r = replies.find(x => x.id === 2);
  assert.equal(r.error, undefined, "a tool failure is not a protocol error");
  assert.equal(r.result.isError, true);
  assert.equal(r.result.content[0].type, "text");
  assert.match(r.result.content[0].text, /ENOENT/);
});

test("a CLI that exits non-zero surfaces its stderr as a tool error result", async () => {
  const bin = makeMockBin("fail");
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg, callMsg(2, "activity_search", { query: "x" }));
  const r = replies.find(x => x.id === 2);
  assert.equal(r.error, undefined);
  assert.equal(r.result.isError, true);
  assert.match(r.result.content[0].text, /boom/);
});

test("activity_search requires query argument", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_search", arguments: {} } });
  const r = replies.find(x => x.id === 2);
  assert.equal(r.error, undefined);
  assert.equal(r.result.isError, true);
  assert.match(r.result.content[0].text, /query required/);
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

test("serverInfo.version comes from the VERSION file", async () => {
  const bin = makeMockBin();
  const expected = readFileSync(resolve(HERE, "..", "VERSION"), "utf8").trim();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
  assert.equal(replies[0].result.serverInfo.version, expected);
});

test("activity_search returns newest-first", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_search", arguments: { query: "e" } } });
  const payload = JSON.parse(replies.find(x => x.id === 2).result.content[0].text);
  assert.equal(payload.length, 2);
  assert.ok(Date.parse(payload[0].ts) >= Date.parse(payload[1].ts), "results must be newest-first");
});

const CROCKFORD_T = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
function msToUlid(ms) {
  let t = "";
  for (let i = 0; i < 10; i++) { t = CROCKFORD_T[ms % 32] + t; ms = Math.floor(ms / 32); }
  return t + "0000000000000000";
}
function isoMicro(ms) {
  return new Date(ms).toISOString().replace("Z", "000Z");
}

test("activity_digest since:ULID filters by the ULID timestamp", async () => {
  const now = Date.now();
  const bin = makeMockBin("ok", isoMicro(now - 7200000), isoMicro(now - 600000));
  const cutoff = msToUlid(now - 3600000);
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_digest", arguments: { window: "since:" + cutoff } } });
  const payload = JSON.parse(replies.find(x => x.id === 2).result.content[0].text);
  assert.equal(payload.total, 1, "only the event newer than the ULID cutoff must remain");
});

test("activity_digest since:garbage errors", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "activity_digest", arguments: { window: "since:short" } } });
  const r = replies.find(x => x.id === 2);
  assert.equal(r.result.isError, true, "garbage since: must be an error");
  assert.match(r.result.content[0].text, /26-char ULID/);
  assert.deepEqual(cliCalls(bin), []);
});

test("resolveBin maps darwin to darwin-named binaries", async () => {
  const src = readFileSync(resolve(HERE, "server.mjs"), "utf8");
  assert.ok(src.includes('darwin: "darwin"'), "darwin must map to darwin, not macos");
  assert.ok(!src.includes('"macos"'), "no macos naming anywhere");
});

test("server answers when launched through a symlinked file", async () => {
  const dir = mkdtempSync(join(tmpdir(), "amesh-link-"));
  const link = join(dir, "server-link.mjs");
  symlinkSync(SERVER, link);
  const { replies } = await rpcCallAt(link, { ACTIVITY_LOG_BIN: makeMockBin() }, initMsg);
  assert.equal(replies.length, 1, "a symlinked launch must still serve requests");
  assert.equal(replies[0].result.serverInfo.name, "activity-mesh");
});

test("server answers when launched through a symlinked directory (dist/current layout)", async () => {
  const root = mkdtempSync(join(tmpdir(), "amesh-dist-"));
  const versioned = join(root, "dist", "9.9.9");
  mkdirSync(join(versioned, "mcp"), { recursive: true });
  copyFileSync(SERVER, join(versioned, "mcp", "server.mjs"));
  writeFileSync(join(versioned, "VERSION"), "9.9.9\n");
  symlinkSync(versioned, join(root, "dist", "current"));
  const { replies } = await rpcCallAt(join(root, "dist", "current", "mcp", "server.mjs"),
    { ACTIVITY_LOG_BIN: makeMockBin() }, initMsg);
  assert.equal(replies.length, 1, "launching through dist/current must still serve requests");
  assert.equal(replies[0].result.serverInfo.version, "9.9.9");
});

test("importing the module does not start the server", async () => {
  const p = spawn(process.execPath, ["--input-type=module", "-e",
    `const m = await import(${JSON.stringify(SERVER)}); console.log(typeof m.handle);`],
    { stdio: ["ignore", "pipe", "pipe"] });
  let out = "", err = "";
  p.stdout.on("data", d => out += d);
  p.stderr.on("data", d => err += d);
  await new Promise(res => p.on("close", res));
  assert.equal(out.trim(), "function");
  assert.ok(!err.includes("starting"), `an importer must not trigger main(): ${err}`);
});

for (const [window, since] of [["1h", "1h"], ["12h", "12h"], ["48h", "48h"], ["7d", "7d"], ["30d", "30d"], ["99999h", "99999h"]]) {
  test(`activity_digest accepts the ${window} window and asks the CLI for ${since}`, async () => {
    const bin = makeMockBin();
    const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg, callMsg(2, "activity_digest", { window }));
    const r = replies.find(x => x.id === 2);
    assert.equal(r.result.isError, false, r.result.content[0].text);
    const payload = JSON.parse(r.result.content[0].text);
    assert.equal(payload.total, 2, "a rolling window must not be clipped to a local day");
    assert.ok(payload.markdown.startsWith(`# Digest: ${window} `));
    assert.ok(cliCalls(bin).some(l => l.includes(`--since ${since} `)), `CLI must be asked for ${since}: ${cliCalls(bin)}`);
  });
}

test("activity_digest rejects windows it cannot honour instead of silently using 24h", async () => {
  const bin = makeMockBin();
  const bad = ["30x", "week", "last week", "", "0h", "0d", "-5h", "1.5h", "5 h", "TODAY", "1h2", "since", "100000h", "007d", "7", 7, null, {}];
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg,
    ...bad.map((w, i) => callMsg(100 + i, "activity_digest", { window: w })));
  bad.forEach((w, i) => {
    const r = replies.find(x => x.id === 100 + i);
    assert.ok(r, `no reply for window ${JSON.stringify(w)}`);
    assert.equal(r.result?.isError, true, `window ${JSON.stringify(w)} must be rejected`);
    assert.match(r.result.content[0].text, /unknown window/);
    assert.match(r.result.content[0].text, /today \| yesterday \| <N>h \| <N>d \| since:<26-char ULID>/);
  });
  assert.deepEqual(cliCalls(bin), [], "validation must happen before the CLI is spawned");
});

test("activity_digest still defaults to today", async () => {
  const bin = makeMockBin("ok", localNoonIso());
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg, callMsg(2, "activity_digest", {}));
  const payload = JSON.parse(replies.find(x => x.id === 2).result.content[0].text);
  assert.equal(payload.window, "today");
  assert.equal(payload.total, 2);
});

test("activity_digest groups events whose scope is an Object.prototype name", async () => {
  const names = ["constructor", "__proto__", "toString", "hasOwnProperty", "valueOf"];
  const ts = localNoonIso();
  const events = names.map((scope, i) => ({ v: 1, id: `01P${i}`, ts, host: "h", agent: "a", kind: "note", scope, summary: `about ${scope}` }));
  const bin = makeMockBin("ok", ts, ts, events);
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg, callMsg(2, "activity_digest", { window: "today" }));
  const r = replies.find(x => x.id === 2);
  assert.equal(r.error, undefined, JSON.stringify(r.error));
  assert.equal(r.result.isError, false, r.result.content[0].text);
  const payload = JSON.parse(r.result.content[0].text);
  assert.equal(payload.total, names.length);
  for (const n of names) {
    assert.ok(Object.hasOwn(payload.groups, n), `group ${n} missing from ${JSON.stringify(payload.groups)}`);
    assert.ok(payload.markdown.includes(`## ${n} (1)`), `heading for ${n} missing`);
  }
});

test("non-object request lines get -32600 and never stop the server", async () => {
  const bin = makeMockBin();
  const { replies, code, stderr } = await rpcCall({ ACTIVITY_LOG_BIN: bin },
    initMsg, "null", "5", '"str"', "true", "[]", '{"jsonrpc":"2.0","id":9,"method":5}', "{bad",
    { jsonrpc: "2.0", id: 3, method: "ping" });
  const invalid = replies.filter(x => x.error?.code === -32600);
  assert.equal(invalid.length, 6, JSON.stringify(replies));
  assert.deepEqual(invalid.map(x => x.id), [null, null, null, null, null, 9]);
  for (const x of invalid) assert.equal(x.error.message, "invalid request");
  assert.equal(replies.filter(x => x.error?.code === -32700).length, 1, "a line that is not JSON stays a parse error");
  assert.ok(replies.some(x => x.id === 3 && x.result), "the server must keep answering after bad lines");
  assert.equal(code, 0);
  assert.ok(!stderr.includes("fatal"), stderr);
});

test("resources/read decodes the URI value before it reaches the CLI", async () => {
  const bin = makeMockBin();
  const uri = "activity://recent/" + encodeURIComponent("project:foo");
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg,
    { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri } });
  const r = replies.find(x => x.id === 2);
  assert.ok(r.result, JSON.stringify(r));
  assert.ok(cliCalls(bin).some(l => l.includes("--scope project:foo") && !l.includes("%3A")), cliCalls(bin).join("\n"));
});

test("resources/read decodes digest windows too", async () => {
  const bin = makeMockBin("ok", isoMicro(Date.now() - 600000));
  const cutoff = msToUlid(Date.now() - 3600000);
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg,
    { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: "activity://digest/" + encodeURIComponent("since:" + cutoff) } },
    { jsonrpc: "2.0", id: 3, method: "resources/read", params: { uri: "activity://digest/48h" } });
  assert.ok(replies.find(x => x.id === 2).result, JSON.stringify(replies.find(x => x.id === 2)));
  assert.ok(replies.find(x => x.id === 3).result, JSON.stringify(replies.find(x => x.id === 3)));
  assert.ok(cliCalls(bin).some(l => l.includes("--since 48h ")), cliCalls(bin).join("\n"));
});

test("resources/read survives a malformed escape and an unsupported uri", async () => {
  const bin = makeMockBin();
  const { replies } = await rpcCall({ ACTIVITY_LOG_BIN: bin }, initMsg,
    { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: "activity://recent/%E0%A4%A" } },
    { jsonrpc: "2.0", id: 3, method: "resources/read", params: {} },
    { jsonrpc: "2.0", id: 4, method: "resources/read", params: { uri: "file:///etc/passwd" } },
    { jsonrpc: "2.0", id: 5, method: "ping" });
  for (const id of [2, 3, 4]) {
    const r = replies.find(x => x.id === id);
    assert.ok(r.error, `resources/read #${id} must be a JSON-RPC error: ${JSON.stringify(r)}`);
    assert.equal(r.error.code, -32000);
  }
  assert.match(replies.find(x => x.id === 3).error.message, /unsupported uri/);
  assert.ok(replies.find(x => x.id === 5).result, "the server must keep answering");
  assert.deepEqual(cliCalls(bin), []);
});
