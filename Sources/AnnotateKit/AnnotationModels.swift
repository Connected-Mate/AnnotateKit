//
//  AnnotationModels.swift
//
//  Model + storage for UI annotations captured in-app, compiled into a structured
//  prompt for AI coding agents (Claude Code, Cursor…).
//

#if DEBUG
import Combine
import SwiftUI
import os

/// One captured piece of UI feedback: where the user tapped, which accessibility
/// element lives there (the iOS equivalent of a CSS selector), and the note typed.
struct Annotation: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    var note: String = ""
    var screenHint: String = ""
    /// Screen coordinates, in points.
    var tapPoint: CGPoint = .zero
    var screenSize: CGSize = .zero
    var elementLabel: String?
    var elementIdentifier: String?
    var elementValue: String?
    var elementType: String = "Element"
    var elementTraits: [String] = []
    var elementFrame: CGRect?
    /// Placement inside the window ("bottom-right", "middle-center"…). Optional so
    /// annotation files from older versions still decode.
    var windowRegion: String?
    /// Visible labels around the tap — grep hints to find the view in source.
    var nearbyTexts: [String] = []
    /// UIKit view chain under the tap, deepest first.
    var viewChain: [String] = []
    var screenshotFilename: String?
}

@MainActor
final class AnnotationStore: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []

    private let logger: Logger

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

        if let data = try? Data(contentsOf: jsonURL),
           let saved = try? JSONDecoder().decode([Annotation].self, from: data) {
            annotations = saved
        }
    }

    private var jsonURL: URL { directory.appendingPathComponent("annotations.json") }
    private var markdownURL: URL { directory.appendingPathComponent("annotations.md") }

    func add(_ annotation: Annotation, screenshot: UIImage?) {
        var annotation = annotation
        if let screenshot, let data = screenshot.pngData() {
            let filename = "capture-\(annotation.id.uuidString.prefix(8)).png"
            try? data.write(to: directory.appendingPathComponent(filename))
            annotation.screenshotFilename = filename
        }
        annotations.append(annotation)
        persist()
        // One JSON line per annotation: stream them live from a connected device with
        // `log stream` / devicectl instead of round-tripping through the pasteboard.
        if let data = try? JSONEncoder().encode(annotation),
           let json = String(data: data, encoding: .utf8) {
            logger.notice("ANNOTATEKIT \(json, privacy: .public)")
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            deleteScreenshot(of: annotations[index])
        }
        annotations.remove(atOffsets: offsets)
        persist()
    }

    func clear() {
        annotations.forEach(deleteScreenshot)
        annotations.removeAll()
        persist()
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

    /// The deliverable: a paste-ready prompt for an AI coding agent.
    func markdownPrompt() -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "App"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let device = UIDevice.current

        var lines: [String] = []
        lines.append("# UI feedback — \(appName)")
        lines.append("")
        lines.append("Annotations captured in-app with AnnotateKit. App v\(version) (\(build)), \(device.model) \(device.systemName) \(device.systemVersion) — \(annotations.count) item(s).")
        lines.append("")

        for (index, a) in annotations.enumerated() {
            lines.append("## \(index + 1). \(a.note.isEmpty ? "(no note)" : a.note)")
            lines.append("- **Screen**: \(a.screenHint)")
            var element = a.elementType
            if let label = a.elementLabel, !label.isEmpty { element += " “\(label)”" }
            if let id = a.elementIdentifier, !id.isEmpty { element += " — accessibilityIdentifier `\(id)`" }
            if let value = a.elementValue, !value.isEmpty { element += " — value “\(value)”" }
            lines.append("- **Element**: \(element)")
            if !a.elementTraits.isEmpty {
                lines.append("- **Traits**: \(a.elementTraits.joined(separator: ", "))")
            }
            if let frame = a.elementFrame {
                lines.append("- **Element frame**: (\(Int(frame.minX)), \(Int(frame.minY))) \(Int(frame.width))×\(Int(frame.height)) pt")
            }
            var tapLine = "- **Tap**: (\(Int(a.tapPoint.x)), \(Int(a.tapPoint.y)))"
            if let region = a.windowRegion { tapLine += " — \(region) area" }
            tapLine += " in a \(Int(a.screenSize.width))×\(Int(a.screenSize.height)) pt window"
            lines.append(tapLine)
            if (a.elementLabel ?? "").isEmpty && (a.elementIdentifier ?? "").isEmpty {
                lines.append("- **Caution**: no accessibility metadata under this tap — locate the element from the screenshot, the window region and the nearby texts.")
            }
            if !a.nearbyTexts.isEmpty {
                lines.append("- **Nearby texts**: " + a.nearbyTexts.map { "“\($0)”" }.joined(separator: ", "))
            }
            if !a.viewChain.isEmpty {
                lines.append("- **UIKit views**: `\(a.viewChain.joined(separator: " < "))`")
            }
            if let file = a.screenshotFilename {
                lines.append("- **Screenshot**: `\(directory.appendingPathComponent(file).path)`")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("To locate each element in code: grep the labels and nearby texts above (`Text(\"…\")`, `Label(\"…\")`, accessibility identifiers). Displayed labels may be localized — if a literal doesn't appear in the source, search the app's String Catalog / .lproj files first to find the key.")
        return lines.joined(separator: "\n")
    }
}
#endif
