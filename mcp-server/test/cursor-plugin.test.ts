import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { resolve } from "node:path";

test("bundled Cursor connector starts MCP and shares iOS annotations", async () => {
  const port = 14747;
  const child = spawn(process.execPath, [resolve("../plugins/annotatekit/scripts/annotatekit-mcp.mjs")], {
    cwd: resolve("."), env: { ...process.env, ANNOTATEKIT_PORT: String(port) }, stdio: ["pipe", "pipe", "pipe"]
  });
  const lines = createInterface({ input: child.stdout! });
  const responses = new Map<number, (value: any) => void>();
  lines.on("line", line => { const value = JSON.parse(line); responses.get(value.id)?.(value); });
  const rpc = (id: number, method: string, params?: unknown) => new Promise<any>((resolveResponse, reject) => {
    responses.set(id, resolveResponse); child.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`); setTimeout(() => reject(new Error(`RPC timeout: ${method}`)), 3000);
  });
  try {
    const initialized = await rpc(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    assert.equal(initialized.result.serverInfo.name, "annotatekit");
    const tools = await rpc(2, "tools/list");
    assert(tools.result.tools.some((tool: { name: string }) => tool.name === "annotatekit_get_pending"));
    let health: Response | undefined;
    for (let attempt = 0; attempt < 20; attempt++) { try { health = await fetch(`http://127.0.0.1:${port}/health`); break; } catch { await new Promise(done => setTimeout(done, 50)); } }
    assert.equal(health?.status, 200);
    const session = await (await fetch(`http://127.0.0.1:${port}/sessions`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ url: "ios://cursor-test" }) })).json() as { id: string };
    await fetch(`http://127.0.0.1:${port}/sessions/${session.id}/annotations`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: "cursor-a1", comment: "Move this exact button", elementIdentifier: "submit-button" }) });
    const pending = await rpc(3, "tools/call", { name: "annotatekit_get_pending", arguments: { sessionId: session.id } });
    assert.match(pending.result.content[0].text, /cursor-a1/);
    const watching = rpc(4, "tools/call", { name: "annotatekit_watch_send", arguments: { sessionId: session.id, timeoutSeconds: 2 } });
    await new Promise(done => setTimeout(done, 25));
    await fetch(`http://127.0.0.1:${port}/sessions/${session.id}/action`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ output: "sent from iOS" }) });
    const sent = await watching;
    assert.match(sent.result.content[0].text, /"sent": true/);
    assert.match(sent.result.content[0].text, /cursor-a1/);
  } finally { child.kill("SIGTERM"); lines.close(); }
});
