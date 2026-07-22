#!/usr/bin/env node
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import process from "node:process";

const sessions = new Map();
const listeners = new Set();
let sequence = 0;

const now = () => new Date().toISOString();
const publicSession = (session) => ({ id: session.id, url: session.url, createdAt: session.createdAt, updatedAt: session.updatedAt, annotationCount: session.annotations.size });
const requiredSession = (id) => { const session = sessions.get(id); if (!session) throw Object.assign(new Error(`Session ${id} not found`), { status: 404 }); return session; };
const emit = (type, sessionId, payload) => { const event = { id: ++sequence, type, sessionId, payload, timestamp: now() }; for (const listener of listeners) listener(event); };
const createSession = (url = "ios://app") => { const timestamp = now(); const session = { id: randomUUID(), url, createdAt: timestamp, updatedAt: timestamp, annotations: new Map() }; sessions.set(session.id, session); emit("session.created", session.id, publicSession(session)); return publicSession(session); };
const pending = (sessionId) => (sessionId ? [requiredSession(sessionId)] : [...sessions.values()]).flatMap(session => [...session.annotations.values()].filter(annotation => ["pending", "acknowledged"].includes(annotation.status)));
const findAnnotation = (id) => { for (const session of sessions.values()) { const annotation = session.annotations.get(id); if (annotation) return { session, annotation }; } throw Object.assign(new Error(`Annotation ${id} not found`), { status: 404 }); };
const updateAnnotation = (session, id, patch) => { const current = session.annotations.get(id); if (!current) throw Object.assign(new Error(`Annotation ${id} not found`), { status: 404 }); const updated = { ...current, ...patch, id, sessionId: session.id, updatedAt: now() }; session.annotations.set(id, updated); session.updatedAt = updated.updatedAt; emit("annotation.updated", session.id, updated); return updated; };

const toolDefinitions = [
  { name: "annotatekit_list_sessions", description: "List active AnnotateKit iOS visual-feedback sessions before reading annotations.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations: { title: "List annotation sessions", readOnlyHint: true, openWorldHint: false, destructiveHint: false } },
  { name: "annotatekit_get_pending", description: "Read pending iOS UI annotations with captured position and accessibility context, optionally for one session.", inputSchema: { type: "object", properties: { sessionId: { type: "string" } }, additionalProperties: false }, annotations: { title: "Get pending annotations", readOnlyHint: true, openWorldHint: false, destructiveHint: false } },
  { name: "annotatekit_get_session", description: "Read one AnnotateKit session and all its annotations by exact session ID.", inputSchema: { type: "object", required: ["sessionId"], properties: { sessionId: { type: "string" } }, additionalProperties: false }, annotations: { title: "Get annotation session", readOnlyHint: true, openWorldHint: false, destructiveHint: false } },
  ...["acknowledge", "resolve", "dismiss"].map(action => ({ name: `annotatekit_${action}`, description: `${action[0].toUpperCase() + action.slice(1)} one exact annotation with a concise summary. Resolve only after the requested change is implemented and verified.`, inputSchema: { type: "object", required: ["annotationId", "summary"], properties: { annotationId: { type: "string" }, summary: { type: "string", minLength: 1, maxLength: 2000 } }, additionalProperties: false }, annotations: { title: `${action[0].toUpperCase() + action.slice(1)} annotation`, readOnlyHint: false, openWorldHint: false, destructiveHint: false } })),
  { name: "annotatekit_reply", description: "Append a visible agent reply to one annotation thread without resolving it.", inputSchema: { type: "object", required: ["annotationId", "message"], properties: { annotationId: { type: "string" }, message: { type: "string", minLength: 1, maxLength: 4000 } }, additionalProperties: false }, annotations: { title: "Reply to annotation", readOnlyHint: false, openWorldHint: false, destructiveHint: false } }
];

const textResult = (value) => ({ content: [{ type: "text", text: JSON.stringify(value, null, 2) }] });
const callTool = (name, args = {}) => {
  if (name === "annotatekit_list_sessions") return textResult([...sessions.values()].map(publicSession));
  if (name === "annotatekit_get_pending") return textResult(pending(args.sessionId));
  if (name === "annotatekit_get_session") { const session = requiredSession(args.sessionId); return textResult({ ...publicSession(session), annotations: [...session.annotations.values()] }); }
  if (["annotatekit_acknowledge", "annotatekit_resolve", "annotatekit_dismiss"].includes(name)) { const { session, annotation } = findAnnotation(args.annotationId); const status = name.replace("annotatekit_", "").replace("acknowledge", "acknowledged").replace("resolve", "resolved").replace("dismiss", "dismissed"); return textResult(updateAnnotation(session, annotation.id, { status, resolution: args.summary, resolvedAt: now(), resolvedBy: "cursor" })); }
  if (name === "annotatekit_reply") { const { session, annotation } = findAnnotation(args.annotationId); const thread = [...(annotation.thread ?? []), { id: randomUUID(), role: "agent", content: args.message, timestamp: Date.now() }]; return textResult(updateAnnotation(session, annotation.id, { thread })); }
  throw new Error(`Unknown tool: ${name}`);
};

const sendRpc = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
let stdinBuffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  stdinBuffer += chunk;
  let newline;
  while ((newline = stdinBuffer.indexOf("\n")) >= 0) {
    const line = stdinBuffer.slice(0, newline).trim(); stdinBuffer = stdinBuffer.slice(newline + 1); if (!line) continue;
    let request;
    try { request = JSON.parse(line); } catch { continue; }
    if (request.id === undefined) continue;
    try {
      let result;
      if (request.method === "initialize") result = { protocolVersion: "2025-06-18", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "annotatekit", version: "0.5.0" } };
      else if (request.method === "ping") result = {};
      else if (request.method === "tools/list") result = { tools: toolDefinitions };
      else if (request.method === "tools/call") result = callTool(request.params?.name, request.params?.arguments);
      else throw Object.assign(new Error(`Method not found: ${request.method}`), { code: -32601 });
      sendRpc({ jsonrpc: "2.0", id: request.id, result });
    } catch (error) { sendRpc({ jsonrpc: "2.0", id: request.id, error: { code: error.code ?? -32000, message: error.message } }); }
  }
});

const readBody = async (request) => { const chunks = []; for await (const chunk of request) chunks.push(Buffer.from(chunk)); return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; };
const json = (response, status, value) => { response.writeHead(status, { "content-type": "application/json", "access-control-allow-origin": "*" }); response.end(JSON.stringify(value)); };
const httpServer = createServer(async (request, response) => {
  try {
    const path = new URL(request.url ?? "/", "http://localhost").pathname; const method = request.method ?? "GET";
    if (path === "/health") return json(response, 200, { ok: true, service: "annotatekit-mcp", version: "0.5.0" });
    if (path === "/sessions" && method === "POST") return json(response, 201, createSession((await readBody(request)).url));
    if (path === "/sessions" && method === "GET") return json(response, 200, [...sessions.values()].map(publicSession));
    let match = path.match(/^\/sessions\/([^/]+)$/);
    if (match && method === "GET") { const session = requiredSession(match[1]); return json(response, 200, { ...publicSession(session), annotations: [...session.annotations.values()] }); }
    match = path.match(/^\/sessions\/([^/]+)\/annotations$/);
    if (match && method === "POST") { const session = requiredSession(match[1]); const input = await readBody(request); const timestamp = now(); const annotation = { ...input, id: typeof input.id === "string" ? input.id : randomUUID(), sessionId: session.id, status: "pending", createdAt: timestamp, updatedAt: timestamp }; session.annotations.set(annotation.id, annotation); session.updatedAt = timestamp; emit("annotation.created", session.id, annotation); return json(response, 201, annotation); }
    match = path.match(/^\/sessions\/([^/]+)\/pending$/);
    if (match && method === "GET") return json(response, 200, { annotations: pending(match[1]) });
    match = path.match(/^\/sessions\/([^/]+)\/action$/);
    if (match && method === "POST") { requiredSession(match[1]); await readBody(request); return json(response, 200, { success: true }); }
    match = path.match(/^\/annotations\/([^/]+)$/);
    if (match && method === "PATCH") { const { session } = findAnnotation(match[1]); return json(response, 200, updateAnnotation(session, match[1], await readBody(request))); }
    if (match && method === "DELETE") { const { session } = findAnnotation(match[1]); session.annotations.delete(match[1]); emit("annotation.deleted", session.id, { id: match[1] }); response.writeHead(204); return response.end(); }
    match = path.match(/^\/sessions\/([^/]+)\/events$/);
    if (match && method === "GET") { requiredSession(match[1]); response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "access-control-allow-origin": "*" }); response.write(": connected\n\n"); const listener = event => { if (event.sessionId === match[1]) response.write(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`); }; listeners.add(listener); const keepAlive = setInterval(() => response.write(": ping\n\n"), 25_000); request.on("close", () => { clearInterval(keepAlive); listeners.delete(listener); }); return; }
    return json(response, 404, { error: "Not found" });
  } catch (error) { return json(response, error.status ?? 500, { error: error.message }); }
});

const port = Number(process.env.ANNOTATEKIT_PORT ?? 4747);
httpServer.on("error", error => { if (error.code === "EADDRINUSE") console.error(`AnnotateKit bridge port ${port} is already in use.`); else console.error(error); });
httpServer.listen(port, "0.0.0.0", () => console.error(`AnnotateKit iOS bridge listening on http://0.0.0.0:${port}`));
