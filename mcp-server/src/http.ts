import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpServer } from "./mcp.js";
import { HttpError, type Store } from "./store.js";

const json = (res: ServerResponse, status: number, value: unknown) => { res.writeHead(status, { "content-type": "application/json", "access-control-allow-origin": "*" }); res.end(JSON.stringify(value)); };
async function body(req: IncomingMessage) { const chunks: Buffer[] = []; for await (const chunk of req) chunks.push(Buffer.from(chunk)); return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; }

export function createHttpServer(store: Store) {
  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", "http://localhost"); const path = url.pathname; const method = req.method ?? "GET";
      if (method === "OPTIONS") { res.writeHead(204, { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,PATCH,DELETE,OPTIONS", "access-control-allow-headers": "content-type,mcp-session-id" }); return res.end(); }
      if (path === "/health") return json(res, 200, { ok: true, service: "annotatekit-mcp", version: "0.5.0" });
      if (path === "/.well-known/mcp.json") return json(res, 200, { name: "AnnotateKit", transport: "streamable-http", endpoint: "/mcp" });
      if (path === "/mcp" && ["GET", "POST", "DELETE"].includes(method)) { const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined }); const mcp = createMcpServer(store); await mcp.connect(transport); await transport.handleRequest(req, res, method === "POST" ? await body(req) : undefined); return; }
      if (path === "/sessions" && method === "POST") return json(res, 201, store.createSession((await body(req)).url));
      if (path === "/sessions" && method === "GET") return json(res, 200, store.listSessions());
      let match = path.match(/^\/sessions\/([^/]+)$/);
      if (match && method === "GET") { const s = store.getSession(match[1]); if (!s) throw new HttpError(404, "Session not found"); return json(res, 200, { ...store.publicSession(s), annotations: [...s.annotations.values()] }); }
      match = path.match(/^\/sessions\/([^/]+)\/annotations$/);
      if (match && method === "POST") return json(res, 201, store.createAnnotation(match[1], await body(req)));
      match = path.match(/^\/sessions\/([^/]+)\/annotations\/([^/]+)$/);
      if (match && method === "PATCH") return json(res, 200, store.update(match[1], match[2], await body(req)));
      if (match && method === "DELETE") { store.delete(match[1], match[2]); res.writeHead(204); return res.end(); }
      match = path.match(/^\/sessions\/([^/]+)\/pending$/);
      if (match && method === "GET") return json(res, 200, { annotations: store.pending(match[1]) });
      match = path.match(/^\/sessions\/([^/]+)\/action$/);
      if (match && method === "POST") { if (!store.getSession(match[1])) throw new HttpError(404, "Session not found"); await body(req); return json(res, 200, { success: true }); }
      match = path.match(/^\/annotations\/([^/]+)$/);
      if (match && method === "PATCH") { const found = store.findAnnotation(match[1]); return json(res, 200, store.update(found.session.id, match[1], await body(req))); }
      if (match && method === "DELETE") { const found = store.findAnnotation(match[1]); store.delete(found.session.id, match[1]); res.writeHead(204); return res.end(); }
      match = path.match(/^\/sessions\/([^/]+)\/events$/);
      if (match && method === "GET") { const sessionId = match[1]; if (!store.getSession(sessionId)) throw new HttpError(404, "Session not found"); res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "access-control-allow-origin": "*" }); res.write(": connected\n\n"); const unsub = store.subscribe(e => { if (e.sessionId === sessionId) res.write(`id: ${e.id}\nevent: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`); }); const keep = setInterval(() => res.write(": ping\n\n"), 25_000); req.on("close", () => { clearInterval(keep); unsub(); }); return; }
      return json(res, 404, { error: "Not found" });
    } catch (error) { const status = error instanceof HttpError ? error.status : 500; json(res, status, { error: error instanceof Error ? error.message : "Internal error" }); }
  });
}
