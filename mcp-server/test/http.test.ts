import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { createHttpServer } from "../src/http.js";
import { Store } from "../src/store.js";

test("iOS session and annotation round-trip", async () => {
  const server = createHttpServer(new Store()).listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address(); assert(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  try {
    const created = await fetch(`${base}/sessions`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ url: "ios://test" }) });
    assert.equal(created.status, 201); const session = await created.json() as { id: string };
    const pushed = await fetch(`${base}/sessions/${session.id}/annotations`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: "a1", comment: "Button overlaps card", element: "Button" }) });
    assert.equal(pushed.status, 201);
    const pending = await (await fetch(`${base}/sessions/${session.id}/pending`)).json() as { annotations: Array<{ id: string }> };
    assert.deepEqual(pending.annotations.map(a => a.id), ["a1"]);
    const updated = await fetch(`${base}/annotations/a1`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ status: "resolved" }) });
    assert.equal(updated.status, 200);
    assert.equal((await fetch(`${base}/sessions/${session.id}/action`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ output: "done" }) })).status, 200);
  } finally { server.close(); }
});

test("health and discovery endpoints", async () => {
  const server = createHttpServer(new Store()).listen(0, "127.0.0.1"); await once(server, "listening");
  const address = server.address(); assert(address && typeof address === "object");
  try { assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200); assert.equal((await fetch(`http://127.0.0.1:${address.port}/.well-known/mcp.json`)).status, 200); }
  finally { server.close(); }
});
