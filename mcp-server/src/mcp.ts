import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Store, Status } from "./store.js";

const annotations = { readOnlyHint: true, openWorldHint: false, destructiveHint: false } as const;
const text = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] });

export function createMcpServer(store: Store) {
  const server = new McpServer({ name: "annotatekit", version: "0.5.0" });
  server.registerTool("annotatekit_list_sessions", { title: "List annotation sessions", description: "List active AnnotateKit iOS visual-feedback sessions. Use this to discover the session ID before reading annotations.", annotations, inputSchema: {} }, async () => text(store.listSessions()));
  server.registerTool("annotatekit_get_pending", { title: "Get pending annotations", description: "Read pending iOS UI annotations, optionally limited to one session. Returns feedback and captured accessibility context needed to implement fixes.", annotations, inputSchema: { sessionId: z.string().optional() } }, async ({ sessionId }) => text(store.pending(sessionId)));
  server.registerTool("annotatekit_get_session", { title: "Get annotation session", description: "Read one AnnotateKit session and all of its annotations by exact session ID.", annotations, inputSchema: { sessionId: z.string() } }, async ({ sessionId }) => { const s = store.getSession(sessionId); if (!s) throw new Error(`Session ${sessionId} not found`); return text({ ...store.publicSession(s), annotations: [...s.annotations.values()] }); });
  const statusTool = (name: string, title: string, status: Status, description: string) => server.registerTool(name, { title, description, annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }, inputSchema: { annotationId: z.string(), summary: z.string().min(1).max(2000) } }, async ({ annotationId, summary }) => { const { session, annotation } = store.findAnnotation(annotationId); return text(store.update(session.id, annotation.id, { status, resolvedAt: new Date().toISOString(), resolvedBy: "agent", resolution: summary })); });
  statusTool("annotatekit_acknowledge", "Acknowledge annotation", "acknowledged", "Mark one annotation as acknowledged after starting work. This changes only its workflow status and is reversible.");
  statusTool("annotatekit_resolve", "Resolve annotation", "resolved", "Mark one annotation resolved after the requested UI change has been implemented and verified. Include a concise implementation summary.");
  statusTool("annotatekit_dismiss", "Dismiss annotation", "dismissed", "Dismiss one annotation only when the user explicitly decides no change is needed. Include the reason.");
  server.registerTool("annotatekit_reply", { title: "Reply to annotation", description: "Append a visible agent reply to an annotation thread. Use for clarification or progress; this does not resolve the annotation.", annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }, inputSchema: { annotationId: z.string(), message: z.string().min(1).max(4000) } }, async ({ annotationId, message }) => { const { session, annotation } = store.findAnnotation(annotationId); const thread = [...(annotation.thread ?? []), { id: crypto.randomUUID(), role: "agent", content: message, timestamp: Date.now() }]; return text(store.update(session.id, annotation.id, { thread })); });
  return server;
}
