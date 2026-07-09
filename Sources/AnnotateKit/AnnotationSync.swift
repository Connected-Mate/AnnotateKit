//
//  AnnotationSync.swift
//
//  Real-time client for an `agentation-mcp` server (HTTP + Server-Sent Events)
//  and for direct webhooks. Field names and wire shapes mirror the web product
//  ("Agentation") exactly, so annotations produced on iOS are accepted as-is by
//  the same server the web client talks to.
//
//  Debug-only, like the rest of the package: in Release this file compiles to
//  nothing and the store's call sites become no-ops.
//
//  Design notes:
//  - Zero dependencies. URLSession only (`data(for:)` for requests, `bytes(for:)`
//    for the SSE stream). Structured concurrency; no DispatchQueue, no polling.
//  - One long-lived Task owns the session + SSE loop with exponential backoff.
//    `stop()` cancels it; `start()` relaunches everything.
//  - The store is held weakly (the store owns the shared singleton indirectly via
//    its call sites, so a strong ref back would be a cycle).
//  - Reconnect parity with the web client: on every (re)connect we push every
//    annotation whose `_syncedTo` doesn't match the live session, so a device that
//    was offline catches the server up.
//

#if DEBUG
import Combine
import Foundation

@MainActor
final class AnnotationSync: ObservableObject {
    static let shared = AnnotationSync()

    enum ConnectionState { case disabled, connecting, connected }
    @Published private(set) var state: ConnectionState = .disabled

    // MARK: - Config / persisted keys

    private static let sessionIDKey = "agentation-session-id"
    private static let sessionEndpointKey = "agentation-session-endpoint"
    private let requestTimeout: TimeInterval = 10
    /// Longer than the server's 30s keep-alive ping so an idle stream isn't torn down.
    private let streamTimeout: TimeInterval = 65

    // MARK: - State

    private weak var store: AnnotationStore?
    /// Base URL string of the server, e.g. "http://192.168.1.20:4747". Empty = disabled.
    private var endpoint = ""
    private var sessionId: String?
    /// De-dupes concurrent session creation (the SSE loop and a live push can race).
    private var sessionTask: Task<String?, Never>?
    private var streamTask: Task<Void, Never>?
    /// Last SSE `id:` seen, replayed as `Last-Event-ID` on reconnect.
    private var lastEventID: String?
    /// Creates that failed while offline; retried on the next connect. The store's
    /// `_syncedTo` filter is the authoritative merge, this is a fast-path buffer.
    /// Ids deleted locally — never re-pushed, whatever retry path finds them.
    private var deletedIds: Set<String> = []

    private init() {}

    // MARK: - Lifecycle

    /// Called at install and whenever `settings.endpoint` changes. Tears down any
    /// existing session/stream and starts fresh.
    func start(store: AnnotationStore) {
        stop()
        self.store = store
        endpoint = store.settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionId = nil

        guard !endpoint.isEmpty else {
            state = .disabled
            return
        }
        state = .connecting
        streamTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        state = .disabled
    }

    // MARK: - Outbound (called from the store, synchronously, on the main actor)

    /// Fire-and-forget: a failed push simply leaves `_syncedTo` unset in the
    /// store, and the next reconnect's flush re-sends it from there — no side
    /// buffer to drift out of sync with deletions.
    func push(_ annotation: Annotation, from store: AnnotationStore) {
        self.store = store
        guard !endpoint.isEmpty else { return }
        Task { [weak self] in
            guard let self, let sid = await self.ensureSession() else { return }
            await self.sendAnnotation(annotation, sessionId: sid)
        }
    }

    func pushUpdate(_ annotation: Annotation) {
        guard !endpoint.isEmpty else { return }
        Task { [weak self] in
            guard let self, let sid = await self.ensureSession() else { return }
            await self.patchAnnotation(annotation, sessionId: sid)
        }
    }

    func pushDelete(_ annotation: Annotation) {
        // Tombstone: no retry path may ever re-create a deleted annotation.
        deletedIds.insert(annotation.id)
        guard !endpoint.isEmpty else { return }
        let id = annotation.id
        Task { [weak self] in
            guard let self, let sid = await self.ensureSession() else { return }
            await self.deleteAnnotation(id: id, sessionId: sid)
        }
    }

    /// POST /sessions/{id}/action — fires the server-side webhooks. Returns false if
    /// there's no endpoint or no session could be established.
    func sendAction(output: String) async -> Bool {
        guard !endpoint.isEmpty else { return false }
        guard let sid = await ensureSession() else { return false }
        guard let url = URL(string: endpoint + "/sessions/\(sid)/action") else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["output": output])

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return false }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = obj["success"] as? Bool {
            return success
        }
        return true
    }

    /// POST directly to a webhook URL (no server needed). Payload is the web
    /// `ActionRequest` shape. Works even when server sync is disabled.
    func fireWebhook(urlString: String, annotations: [Annotation], output: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }

        let cleaned = annotations.map(wireCopy)
        guard let annData = try? JSONEncoder().encode(cleaned),
              let annArray = try? JSONSerialization.jsonObject(with: annData) else { return false }

        let persistedSession = sessionId
            ?? UserDefaults.standard.string(forKey: Self.sessionIDKey)
            ?? ""
        let payload: [String: Any] = [
            "sessionId": persistedSession,
            "annotations": annArray,
            "output": output,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Agentation-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = body

        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return false }
        return true
    }

    // MARK: - Session

    private func sessionURLValue() -> String {
        "ios://" + (Bundle.main.bundleIdentifier ?? "app")
    }

    /// Returns a session id, reusing the in-memory one, then a persisted one that
    /// matches the current endpoint, otherwise creating a fresh session. Concurrent
    /// callers share a single in-flight creation.
    private func ensureSession() async -> String? {
        if let sessionId { return sessionId }
        if let sessionTask { return await sessionTask.value }

        let defaults = UserDefaults.standard
        if let persisted = defaults.string(forKey: Self.sessionIDKey),
           defaults.string(forKey: Self.sessionEndpointKey) == endpoint {
            sessionId = persisted
            return persisted
        }

        let task = Task { [weak self] () -> String? in
            await self?.createSession()
        }
        sessionTask = task
        let result = await task.value
        sessionTask = nil
        return result
    }

    private func createSession() async -> String? {
        guard let url = URL(string: endpoint + "/sessions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": sessionURLValue()])

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }

        sessionId = id
        persistSession(id: id)
        return id
    }

    private func persistSession(id: String) {
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: Self.sessionIDKey)
        defaults.set(endpoint, forKey: Self.sessionEndpointKey)
    }

    private func clearPersistedSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.sessionIDKey)
        defaults.removeObject(forKey: Self.sessionEndpointKey)
    }

    // MARK: - Main loop (session → flush → stream → reconnect)

    private func run() async {
        var backoffSeconds: Double = 1
        while !Task.isCancelled {
            guard let sid = await ensureSession() else {
                state = .connecting
                await backoffSleep(&backoffSeconds)
                continue
            }

            await flushUnsynced(sessionId: sid)
            if Task.isCancelled { return }

            // The flush's 404 recovery may have replaced the session.
            let opened = await openStream(sessionId: sessionId ?? sid)
            if Task.isCancelled { return }

            // A clean disconnect after a live stream reconnects promptly; repeated
            // connect failures keep growing the backoff toward the cap.
            if opened { backoffSeconds = 1 }
            state = .connecting
            await backoffSleep(&backoffSeconds)
        }
    }

    private func backoffSleep(_ seconds: inout Double) async {
        let clamped = min(seconds, 30)
        try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
        seconds = min(seconds * 2, 30)
    }

    /// Push every annotation the live session hasn't acknowledged yet — the
    /// store's `_syncedTo` is the single source of truth. Tombstones skipped.
    private func flushUnsynced(sessionId initialSid: String) async {
        guard let store else { return }
        for annotation in store.annotations {
            if Task.isCancelled { return }
            guard !deletedIds.contains(annotation.id) else { continue }
            // sendAnnotation's 404 recovery can replace the session mid-loop —
            // always target the current one, so one dead session doesn't mint
            // a fresh session per queued annotation.
            let sid = sessionId ?? initialSid
            guard annotation._syncedTo != sid else { continue }
            _ = await sendAnnotation(annotation, sessionId: sid)
        }
    }

    // MARK: - SSE stream

    /// Opens the event stream and pumps it until it ends or the task is cancelled.
    /// Returns true if the stream opened successfully at least once.
    private func openStream(sessionId sid: String) async -> Bool {
        if Task.isCancelled { return false }
        guard let url = URL(string: endpoint + "/sessions/\(sid)/events") else { return false }

        var req = URLRequest(url: url)
        req.timeoutInterval = streamTimeout
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 404 {
                // Session is gone server-side; drop it so the next loop recreates one.
                sessionId = nil
                clearPersistedSession()
                return false
            }
            guard (200...299).contains(http.statusCode) else { return false }

            state = .connected
            var eventType = ""
            var dataLines: [String] = []
            var lineBytes: [UInt8] = []

            // Byte-level framing: `bytes.lines` silently skips blank lines, and the
            // blank line is exactly what terminates an SSE event.
            for try await byte in bytes {
                if Task.isCancelled { break }
                if byte == 0x0D { continue }
                guard byte == 0x0A else {
                    lineBytes.append(byte)
                    continue
                }
                let line = String(decoding: lineBytes, as: UTF8.self)
                lineBytes.removeAll(keepingCapacity: true)

                if line.isEmpty {
                    if !dataLines.isEmpty {
                        handleEvent(type: eventType, data: dataLines.joined(separator: "\n"))
                    }
                    eventType = ""
                    dataLines.removeAll()
                } else if line.hasPrefix("event:") {
                    eventType = sseValue(line, prefix: 6)
                } else if line.hasPrefix("data:") {
                    dataLines.append(sseValue(line, prefix: 5))
                } else if line.hasPrefix("id:") {
                    lastEventID = sseValue(line, prefix: 3)
                }
                // Comment lines (":" prefix, keep-alive pings) and unknown fields: ignored.
            }
            return true
        } catch {
            return false
        }
    }

    /// Value of an SSE field line after the prefix, with a single optional leading space stripped.
    private func sseValue(_ line: String, prefix: Int) -> String {
        var value = line.dropFirst(prefix)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }

    private func handleEvent(type: String, data: String) {
        guard let store,
              let jsonData = data.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        // Envelope: {type, timestamp, sessionId, sequence, payload}
        let eventName = (envelope["type"] as? String) ?? type
        let payload = envelope["payload"]

        switch eventName {
        case "annotation.updated":
            // Payload is the annotation. Extract fields manually — a full `Annotation`
            // decode would reject any payload missing the iOS-only required fields.
            guard let dict = payload as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let status = (dict["status"] as? String).flatMap(AnnotationStatus.init(rawValue:)) ?? .pending
            store.applyRemoteStatus(id: id, status: status, thread: decodeThread(dict["thread"]))

        case "annotation.deleted":
            let id: String?
            if let dict = payload as? [String: Any] {
                id = dict["id"] as? String
            } else {
                id = payload as? String
            }
            if let id { store.removeLocally(id: id) }

        default:
            break
        }
    }

    private func decodeThread(_ value: Any?) -> [ThreadMessage]? {
        guard let array = value as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: array) else { return nil }
        return try? JSONDecoder().decode([ThreadMessage].self, from: data)
    }

    // MARK: - HTTP verbs on annotations

    /// POST create. On a 404 (session gone) recreates the session and retries once.
    /// The server assigns its own annotation id (the client-sent one is ignored);
    /// the local annotation adopts the returned id so SSE events match.
    @discardableResult
    private func sendAnnotation(_ annotation: Annotation, sessionId sid: String) async -> Bool {
        guard !deletedIds.contains(annotation.id) else { return false }
        guard let result = await postAnnotation(annotation, sessionId: sid) else { return false }

        if result.code == 404 {
            sessionId = nil
            clearPersistedSession()
            guard let newSid = await createSession(),
                  let retry = await postAnnotation(annotation, sessionId: newSid),
                  (200...299).contains(retry.code) else { return false }
            store?.markSynced(id: annotation.id, sessionId: newSid, serverId: retry.serverId)
            return true
        }

        guard (200...299).contains(result.code) else { return false }
        store?.markSynced(id: annotation.id, sessionId: sid, serverId: result.serverId)
        return true
    }

    /// Returns the HTTP status code and the server-assigned annotation id, or nil
    /// on a transport error.
    private func postAnnotation(
        _ annotation: Annotation, sessionId sid: String
    ) async -> (code: Int, serverId: String?)? {
        guard let url = URL(string: endpoint + "/sessions/\(sid)/annotations"),
              let body = encodeForWire(annotation, sessionId: sid) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        let serverId = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["id"] as? String }
        return (http.statusCode, serverId)
    }

    private func patchAnnotation(_ annotation: Annotation, sessionId sid: String) async {
        guard let url = URL(string: endpoint + "/annotations/\(annotation.id)"),
              let body = encodeForWire(annotation, sessionId: sid) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return }
        // Not on the server yet → create it instead.
        if http.statusCode == 404 {
            _ = await sendAnnotation(annotation, sessionId: sid)
        }
    }

    private func deleteAnnotation(id: String, sessionId sid: String) async {
        guard let url = URL(string: endpoint + "/annotations/\(id)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = requestTimeout
        // Best effort — 200/204/404 are all acceptable outcomes.
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Local-only fields dropped — nil optionals are omitted by the synthesized encoder.
    private func wireCopy(_ annotation: Annotation) -> Annotation {
        var copy = annotation
        copy._syncedTo = nil
        copy._anchorId = nil
        copy._anchorLabel = nil
        copy.strokes = nil
        return copy
    }

    /// Wire form of an annotation: local-only fields dropped, session id and url stamped.
    private func encodeForWire(_ annotation: Annotation, sessionId sid: String) -> Data? {
        var copy = wireCopy(annotation)
        copy.sessionId = sid
        if copy.url?.isEmpty != false { copy.url = sessionURLValue() }
        return try? JSONEncoder().encode(copy)
    }
}
#endif
