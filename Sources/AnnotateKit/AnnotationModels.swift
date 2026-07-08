//
//  AnnotationModels.swift
//
//  Annotation schema + store. Field names deliberately mirror Agentation's
//  published annotation schema (id, x, y, comment, element, elementPath,
//  selectedText, boundingBox, intent, severity, status, thread…) so an
//  annotation produced on iOS is accepted as-is by the `agentation-mcp`
//  server and readable by any tool that already understands that schema.
//  iOS-specific context (accessibility traits, view chain, screenshot…) rides
//  along as extra fields.
//

#if DEBUG
import Combine
import SwiftUI
import os

// MARK: - Schema (wire-compatible with Agentation)

/// {x, y, width, height} — encoded as a JSON object, like the web schema
/// (CGRect would encode as nested arrays).
struct Box: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum AnnotationKind: String, Codable { case feedback, placement, rearrange }
enum AnnotationIntent: String, Codable, CaseIterable { case fix, change, question, approve }
enum AnnotationSeverity: String, Codable, CaseIterable { case blocking, important, suggestion }
enum AnnotationStatus: String, Codable { case pending, acknowledged, resolved, dismissed }

struct ThreadMessage: Codable, Identifiable {
    var id: String
    var role: String // "human" | "agent"
    var content: String
    var timestamp: Double
}

struct AnnotationPlacement: Codable {
    var componentType: String
    var width: Double
    var height: Double
    var scrollY: Double
    var text: String?
}

struct AnnotationRearrange: Codable {
    var selector: String
    var label: String
    var tagName: String
    var originalRect: Box
    var currentRect: Box
}

struct Annotation: Codable, Identifiable {
    // Agentation schema
    var id: String = UUID().uuidString
    /// Horizontal position as a percentage of the window width (0–100).
    var x: Double = 0
    /// Vertical position in points from the top of the window.
    var y: Double = 0
    var comment: String = ""
    var element: String = "Element"
    var elementPath: String = ""
    /// Milliseconds since epoch.
    var timestamp: Double = Date.now.timeIntervalSince1970 * 1000
    var selectedText: String?
    var boundingBox: Box?
    var nearbyText: String?
    var cssClasses: String?
    var nearbyElements: String?
    var computedStyles: String?
    var fullPath: String?
    var accessibility: String?
    var isMultiSelect: Bool?
    var isFixed: Bool?
    var elementBoundingBoxes: [Box]?
    var kind: AnnotationKind = .feedback
    var placement: AnnotationPlacement?
    var rearrange: AnnotationRearrange?
    var intent: AnnotationIntent?
    var severity: AnnotationSeverity?
    var status: AnnotationStatus = .pending
    var thread: [ThreadMessage]?
    var sessionId: String?
    var url: String?
    var createdAt: String?
    var updatedAt: String?
    var resolvedAt: String?
    var resolvedBy: String?

    // iOS context (extra fields; the server passes unknown fields through)
    var screenHint: String = ""
    var windowRegion: String?
    var elementIdentifier: String?
    var elementValue: String?
    var elementTraits: [String] = []
    var viewChain: [String] = []
    var screenshotFilename: String?
    /// Freehand strokes from draw mode, in window points.
    var strokes: [[[Double]]]?

    /// Local bookkeeping — session this annotation was pushed to. Never sent.
    var _syncedTo: String?

    var displayTitle: String { comment.isEmpty ? "(no note)" : comment }

    init() {}

    // Tolerant decoding: every field optional-with-default, so files written by
    // any earlier schema still load instead of being silently wiped on the next
    // persist. Legacy pre-0.2 fields (note, tapPoint, elementLabel…) are mapped.
    // encode(to:) stays synthesized — new files are written in the new schema.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StringKey.self)

        func value<T: Decodable>(_ key: String) -> T? {
            try? c.decodeIfPresent(T.self, forKey: StringKey(key))
        }

        id = value("id") ?? UUID().uuidString
        comment = value("comment") ?? value("note") ?? ""
        element = value("element") ?? "Element"
        elementPath = value("elementPath") ?? ""
        timestamp = value("timestamp")
            ?? (value("date") as Double?).map { ($0 + 978_307_200) * 1000 } // Date → ms epoch
            ?? Date.now.timeIntervalSince1970 * 1000
        selectedText = value("selectedText")
        boundingBox = value("boundingBox")
        nearbyText = value("nearbyText") ?? (value("nearbyTexts") as [String]?)?.joined(separator: " · ")
        cssClasses = value("cssClasses")
        nearbyElements = value("nearbyElements")
        computedStyles = value("computedStyles")
        fullPath = value("fullPath")
        accessibility = value("accessibility")
        isMultiSelect = value("isMultiSelect")
        isFixed = value("isFixed")
        elementBoundingBoxes = value("elementBoundingBoxes")
        kind = value("kind") ?? .feedback
        placement = value("placement")
        rearrange = value("rearrange")
        intent = value("intent")
        severity = value("severity")
        status = value("status") ?? .pending
        thread = value("thread")
        sessionId = value("sessionId")
        url = value("url")
        createdAt = value("createdAt")
        updatedAt = value("updatedAt")
        resolvedAt = value("resolvedAt")
        resolvedBy = value("resolvedBy")
        screenHint = value("screenHint") ?? ""
        windowRegion = value("windowRegion")
        elementIdentifier = value("elementIdentifier")
        elementValue = value("elementValue")
        elementTraits = value("elementTraits") ?? []
        viewChain = value("viewChain") ?? []
        screenshotFilename = value("screenshotFilename")
        strokes = value("strokes")
        _syncedTo = value("_syncedTo")

        // Legacy position: tapPoint [x, y] + screenSize [w, h] in points.
        if x == 0, y == 0, let tap = value("tapPoint") as [Double]?, tap.count == 2 {
            y = tap[1]
            if let size = value("screenSize") as [Double]?, size.count == 2, size[0] > 0 {
                x = tap[0] / size[0] * 100
            }
        } else {
            x = value("x") ?? 0
            y = value("y") ?? 0
        }
        // Legacy element identity: elementType + elementLabel.
        if element == "Element", let type = value("elementType") as String? {
            element = type
            if let label = value("elementLabel") as String?, !label.isEmpty {
                element += " “\(label)”"
            }
        }
        // Old files had no elementPath — the element identity is the best selector left.
        if elementPath.isEmpty {
            elementPath = (value("viewChain") as [String]?)?.reversed().joined(separator: " > ") ?? element
            if elementPath.isEmpty { elementPath = element }
        }
    }

    private struct StringKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Settings (mirrors Agentation's ToolbarSettings)

struct AnnotationSettings: Codable {
    var accent: AnnotationTheme.Accent = .blue
    var theme: AnnotationTheme.ThemeMode = .dark
    var markerClickBehavior: MarkerClickBehavior = .edit
    var detailLevel: OutputDetailLevel = .standard
    var noteInput: NoteInput = .both
    var webhookURL: String = ""
    var endpoint: String = ""

    enum MarkerClickBehavior: String, Codable, CaseIterable { case edit, delete }

    /// Type, dictate, or both.
    /// `voice` never shows the keyboard — one tap on the mic starts on-device
    /// dictation, the transcript becomes the note.
    enum NoteInput: String, Codable, CaseIterable { case keyboard, voice, both }

    static let defaultsKey = "feedback-toolbar-settings"

    @MainActor
    static func load() -> AnnotationSettings {
        var settings = AnnotationSettings()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(AnnotationSettings.self, from: data) {
            settings = saved
        }
        // Code-level configure() fills any field the user hasn't set in-app —
        // persisted-but-empty must not silently disable it.
        if settings.endpoint.isEmpty, let url = AnnotateKit.configuration.endpoint {
            settings.endpoint = url.absoluteString
        }
        if settings.webhookURL.isEmpty, let url = AnnotateKit.configuration.webhookURL {
            settings.webhookURL = url.absoluteString
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum OutputDetailLevel: String, Codable, CaseIterable { case compact, standard, detailed, forensic }

// MARK: - Store

@MainActor
final class AnnotationStore: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []
    @Published var settings: AnnotationSettings {
        didSet { settings.save() }
    }

    private let logger: Logger

    /// Old local id → server-assigned id. UI copies (an open edit popup) can hold
    /// an annotation whose id was swapped by a push completing underneath them.
    private var idAliases: [String: String] = [:]

    /// Annotations older than this are pruned on launch — same 7-day retention
    /// as Agentation's localStorage store.
    static let retentionDays: Double = 7

    /// Where annotations.json / annotations.md / screenshots live. With an App Group
    /// configured, a Mac Catalyst run drops them where a desktop agent can read them
    /// directly (~/Library/Group Containers/…/AnnotateKit/).
    let directory: URL

    init() {
        let fm = FileManager.default
        let base = AnnotateKit.configuration.appGroupIdentifier
            .flatMap { fm.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("AnnotateKit", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let subsystem = AnnotateKit.configuration.logSubsystem
            ?? Bundle.main.bundleIdentifier
            ?? "AnnotateKit"
        logger = Logger(subsystem: subsystem, category: "AnnotateKit")
        settings = AnnotationSettings.load()

        if let data = try? Data(contentsOf: jsonURL),
           let saved = try? JSONDecoder().decode([Annotation].self, from: data) {
            let cutoff = (Date.now.timeIntervalSince1970 - Self.retentionDays * 86400) * 1000
            annotations = saved.filter { $0.timestamp >= cutoff }
            if annotations.count != saved.count { persist() }
        }
    }

    private var jsonURL: URL { directory.appendingPathComponent("annotations.json") }
    private var markdownURL: URL { directory.appendingPathComponent("annotations.md") }

    /// Index of an annotation, following the id alias chain if its id was
    /// swapped for the server one while the caller held a copy.
    private func index(of id: String) -> Int? {
        var id = id
        var hops = 0
        while hops < 8 {
            if let index = annotations.firstIndex(where: { $0.id == id }) { return index }
            guard let next = idAliases[id] else { return nil }
            id = next
            hops += 1
        }
        return nil
    }

    func add(_ annotation: Annotation, screenshot: UIImage?) {
        var annotation = annotation
        if let screenshot {
            let filename = "capture-\(annotation.id.prefix(8)).png"
            annotation.screenshotFilename = filename
            // PNG encoding + disk write off the main actor — a full-screen 3x
            // screenshot is a visible hitch otherwise.
            let url = directory.appendingPathComponent(filename)
            Task.detached(priority: .utility) {
                try? screenshot.pngData()?.write(to: url)
            }
        }
        annotations.append(annotation)
        persist()
        // One JSON line per annotation: stream them live from a connected device with
        // `log stream` / devicectl instead of round-tripping through the pasteboard.
        if let json = encodeToJSON(annotation) {
            logger.notice("ANNOTATEKIT \(json, privacy: .public)")
            AnnotateKit.configuration.callbacks.onAnnotationAdd?(json)
        }
        AnnotationSync.shared.push(annotation, from: self)
    }

    func update(_ annotation: Annotation) {
        guard let index = index(of: annotation.id) else { return }
        var annotation = annotation
        // Keep the stored identity (possibly server-assigned) — not the stale copy's.
        annotation.id = annotations[index].id
        annotation._syncedTo = annotations[index]._syncedTo
        annotation.sessionId = annotations[index].sessionId
        annotations[index] = annotation
        persist()
        if let json = encodeToJSON(annotation) {
            AnnotateKit.configuration.callbacks.onAnnotationUpdate?(json)
        }
        AnnotationSync.shared.pushUpdate(annotation)
    }

    /// Local bookkeeping after a successful push — not a user edit, no callbacks.
    /// The server mints its own annotation ids and returns them in the 201 body;
    /// adopt that id locally, otherwise SSE status updates would never match.
    func markSynced(id: String, sessionId: String, serverId: String? = nil) {
        guard let index = index(of: id) else { return }
        if let serverId, !serverId.isEmpty, serverId != annotations[index].id {
            idAliases[annotations[index].id] = serverId
            annotations[index].id = serverId
        }
        annotations[index]._syncedTo = sessionId
        annotations[index].sessionId = sessionId
        persist()
    }

    /// Applied from the server (SSE): agents resolving/dismissing remove the
    /// annotation locally, like the web client does.
    func applyRemoteStatus(id: String, status: AnnotationStatus, thread: [ThreadMessage]?) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if status == .resolved || status == .dismissed {
            removeLocally(id: id)
        } else {
            annotations[index].status = status
            if let thread { annotations[index].thread = thread }
            persist()
        }
    }

    /// Server-initiated removal — deletes locally without echoing a DELETE back.
    func removeLocally(id: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        deleteScreenshot(of: annotations[index])
        annotations.remove(at: index)
        persist()
    }

    func remove(_ annotation: Annotation) {
        guard let index = index(of: annotation.id) else { return }
        let stored = annotations[index]
        deleteScreenshot(of: stored)
        annotations.remove(at: index)
        persist()
        if let json = encodeToJSON(stored) {
            AnnotateKit.configuration.callbacks.onAnnotationDelete?(json)
        }
        AnnotationSync.shared.pushDelete(stored)
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.map { annotations[$0] }
        doomed.forEach(remove)
    }

    func clear() {
        let doomed = annotations
        annotations.removeAll()
        doomed.forEach(deleteScreenshot)
        persist()
        AnnotateKit.configuration.callbacks.onAnnotationClear?()
        doomed.forEach(AnnotationSync.shared.pushDelete)
    }

    private func deleteScreenshot(of annotation: Annotation) {
        guard let filename = annotation.screenshotFilename else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(annotations) {
            try? data.write(to: jsonURL)
        }
        try? Data(markdownPrompt().utf8).write(to: markdownURL)
    }

    /// Public-facing JSON (callbacks, OSLog stream): the published schema, with
    /// local-only bookkeeping stripped.
    private func encodeToJSON(_ annotation: Annotation) -> String? {
        var copy = annotation
        copy._syncedTo = nil
        guard let data = try? JSONEncoder().encode(copy) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The deliverable: a paste-ready prompt for an AI coding agent.
    func markdownPrompt(level: OutputDetailLevel? = nil) -> String {
        AnnotationOutput.generate(
            annotations: annotations,
            level: level ?? settings.detailLevel,
            screenshotDirectory: directory
        )
    }
}
#endif
