import { randomUUID } from "node:crypto";

export type Status = "pending" | "acknowledged" | "resolved" | "dismissed";
export type Annotation = Record<string, unknown> & {
  id: string; sessionId: string; comment?: string; status: Status;
  createdAt: string; updatedAt: string; thread?: Array<Record<string, unknown>>;
};
export type Session = { id: string; url: string; createdAt: string; updatedAt: string; annotations: Map<string, Annotation> };
export type ConnectorEvent = { id: number; type: string; sessionId: string; payload: unknown; timestamp: string };

export class Store {
  readonly sessions = new Map<string, Session>();
  private listeners = new Set<(event: ConnectorEvent) => void>();
  private sequence = 0;

  createSession(url = "ios://app") {
    const now = new Date().toISOString();
    const session: Session = { id: randomUUID(), url, createdAt: now, updatedAt: now, annotations: new Map() };
    this.sessions.set(session.id, session);
    this.emit("session.created", session.id, this.publicSession(session));
    return this.publicSession(session);
  }
  listSessions() { return [...this.sessions.values()].map(s => this.publicSession(s)); }
  getSession(id: string) { return this.sessions.get(id); }
  publicSession(s: Session) { return { id: s.id, url: s.url, createdAt: s.createdAt, updatedAt: s.updatedAt, annotationCount: s.annotations.size }; }
  createAnnotation(sessionId: string, input: Record<string, unknown>) {
    const session = this.requiredSession(sessionId); const now = new Date().toISOString();
    const annotation: Annotation = { ...input, id: typeof input.id === "string" ? input.id : randomUUID(), sessionId, status: "pending", createdAt: now, updatedAt: now };
    session.annotations.set(annotation.id, annotation); session.updatedAt = now;
    this.emit("annotation.created", sessionId, annotation); return annotation;
  }
  pending(sessionId?: string) {
    const sessions = sessionId ? [this.requiredSession(sessionId)] : [...this.sessions.values()];
    return sessions.flatMap(s => [...s.annotations.values()].filter(a => a.status === "pending" || a.status === "acknowledged"));
  }
  update(sessionId: string, id: string, patch: Record<string, unknown>) {
    const session = this.requiredSession(sessionId); const current = session.annotations.get(id);
    if (!current) throw new HttpError(404, `Annotation ${id} not found`);
    const updated = { ...current, ...patch, id, sessionId, updatedAt: new Date().toISOString() } as Annotation;
    session.annotations.set(id, updated); session.updatedAt = updated.updatedAt;
    this.emit("annotation.updated", sessionId, updated); return updated;
  }
  delete(sessionId: string, id: string) {
    const session = this.requiredSession(sessionId);
    if (!session.annotations.delete(id)) throw new HttpError(404, `Annotation ${id} not found`);
    this.emit("annotation.deleted", sessionId, { id });
  }
  findAnnotation(id: string) {
    for (const session of this.sessions.values()) { const annotation = session.annotations.get(id); if (annotation) return { session, annotation }; }
    throw new HttpError(404, `Annotation ${id} not found`);
  }
  subscribe(listener: (event: ConnectorEvent) => void) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  private emit(type: string, sessionId: string, payload: unknown) {
    const event = { id: ++this.sequence, type, sessionId, payload, timestamp: new Date().toISOString() };
    for (const listener of this.listeners) listener(event);
  }
  private requiredSession(id: string) { const s = this.sessions.get(id); if (!s) throw new HttpError(404, `Session ${id} not found`); return s; }
}

export class HttpError extends Error { constructor(readonly status: number, message: string) { super(message); } }
