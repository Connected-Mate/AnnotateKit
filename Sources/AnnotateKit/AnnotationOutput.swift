//
//  AnnotationOutput.swift
//
//  Turns captured annotations into the markdown handed to an AI coding agent —
//  the iOS counterpart of Agentation's generate-output.ts. Four detail levels
//  trade context size for completeness: `compact` is a one-line-per-note
//  summary, `forensic` dumps everything captured (styles, accessibility, view
//  chain) plus a run environment block.
//

#if DEBUG
import UIKit

@MainActor
enum AnnotationOutput {

    static func generate(annotations: [Annotation], level: OutputDetailLevel, screenshotDirectory: URL) -> String {
        var lines: [String] = ["## UI Feedback: \(appName)"]

        switch level {
        case .compact:
            break
        case .standard, .detailed:
            lines.append("**Viewport:** \(viewportLine)")
        case .forensic:
            lines.append("")
            lines.append("**Environment:**")
            lines.append("- Viewport: \(viewportSize) @\(screenScale)x")
            lines.append("- App: \(appName) v\(appVersion) (\(appBuild))")
            lines.append("- Device: \(deviceLine)")
            lines.append("- Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        }
        lines.append("")

        guard !annotations.isEmpty else {
            lines.append("No annotations.")
            return lines.joined(separator: "\n")
        }

        if level == .compact {
            for (index, annotation) in annotations.enumerated() {
                lines.append(compactLine(index + 1, annotation))
            }
        } else {
            for (index, annotation) in annotations.enumerated() {
                lines.append(contentsOf: block(for: annotation, number: index + 1, level: level, screenshotDirectory: screenshotDirectory))
                lines.append("")
            }
            lines.append("---")
            lines.append(footer)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Compact

    private static func compactLine(_ number: Int, _ a: Annotation) -> String {
        var line = "\(number). **\(a.element)**"
        if !a.screenHint.isEmpty { line += " (\(a.screenHint))" }
        line += ": \(a.displayTitle)"
        if let text = a.selectedText, !text.isEmpty {
            line += " (re: \"\(truncated(text, limit: 30))\")"
        }
        return line
    }

    // MARK: - Standard / detailed / forensic

    private static func block(for a: Annotation, number: Int, level: OutputDetailLevel, screenshotDirectory: URL) -> [String] {
        var lines = ["### \(number). \(a.element)"]

        lines.append(locationLine(for: a))
        if a.isMultiSelect == true {
            lines.append("**Multi-select:** \(a.elementBoundingBoxes?.count ?? 0) elements")
        }
        lines.append("**Screen:** \(a.screenHint)")

        if level == .detailed || level == .forensic {
            if let identifier = a.elementIdentifier, !identifier.isEmpty {
                lines.append("**Identifier:** \(identifier)")
            }
            if let classes = a.cssClasses, !classes.isEmpty {
                lines.append("**Classes:** \(classes)")
            }
            if let box = a.boundingBox {
                lines.append("**Position:** (\(roundedInt(box.x)), \(roundedInt(box.y))) \(roundedInt(box.width))×\(roundedInt(box.height)) pt")
            }
            if a.selectedText == nil, let nearby = a.nearbyText, !nearby.isEmpty {
                lines.append("**Context:** \(nearby)")
            }
            if !a.elementTraits.isEmpty {
                lines.append("**Traits:** \(a.elementTraits.joined(separator: ", "))")
            }
        }

        if let text = a.selectedText, !text.isEmpty {
            lines.append("**Selected text:** \"\(text)\"")
        }
        let intentParts = [a.intent?.rawValue, a.severity?.rawValue].compactMap { $0 }
        if !intentParts.isEmpty {
            lines.append("**Intent:** \(intentParts.joined(separator: " — "))")
        }

        if level == .forensic {
            lines.append("**Annotation at:** \(roundedInt(a.x))% from left, \(roundedInt(a.y))pt from top")
            if let region = a.windowRegion, !region.isEmpty {
                lines.append("**Region:** \(region)")
            }
            if let styles = a.computedStyles, !styles.isEmpty {
                lines.append("**Computed styles:** \(styles)")
            }
            if let accessibility = a.accessibility, !accessibility.isEmpty {
                lines.append("**Accessibility:** \(accessibility)")
            }
            if let nearbyElements = a.nearbyElements, !nearbyElements.isEmpty {
                lines.append("**Nearby elements:** \(nearbyElements)")
            }
            if !a.viewChain.isEmpty {
                lines.append("**View chain:** `\(a.viewChain.joined(separator: " < "))`")
            }
            if let value = a.elementValue, !value.isEmpty {
                lines.append("**Value:** \(value)")
            }
        }

        // The agent's safety net when the accessibility tree had nothing to say.
        if a.kind == .feedback, (a.accessibility ?? "").isEmpty {
            lines.append("**Caution:** no accessibility metadata under this tap — locate the element from the screenshot, the window region and the nearby texts.")
        }
        lines.append("**Feedback:** \(a.displayTitle)")
        // Screenshot at every non-compact level: it's the strongest context an
        // agent gets, not a detail.
        if let filename = a.screenshotFilename {
            lines.append("**Screenshot:** \(screenshotDirectory.appendingPathComponent(filename).path)")
        }
        return lines
    }

    private static func locationLine(for a: Annotation) -> String {
        switch a.kind {
        case .placement:
            guard let placement = a.placement else { return "**Location:** \(a.elementPath)" }
            var line = "**Placement:** \(placement.componentType) \(roundedInt(placement.width))×\(roundedInt(placement.height)) pt"
            if let text = placement.text, !text.isEmpty {
                line += ", \"\(text)\""
            }
            return line
        case .rearrange:
            guard let rearrange = a.rearrange else { return "**Location:** \(a.elementPath)" }
            let original = rearrange.originalRect
            let current = rearrange.currentRect
            return "**Rearrange:** \(rearrange.label) (\(rearrange.tagName)) moved/resized from "
                + "(\(roundedInt(original.x)), \(roundedInt(original.y))) \(roundedInt(original.width))×\(roundedInt(original.height))"
                + " to (\(roundedInt(current.x)), \(roundedInt(current.y))) \(roundedInt(current.width))×\(roundedInt(current.height))"
        case .feedback:
            return "**Location:** \(a.elementPath)"
        }
    }

    // MARK: - Environment

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    private static var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    private static var deviceModel: String { UIDevice.current.model }
    private static var systemName: String { UIDevice.current.systemName }
    private static var systemVersion: String { UIDevice.current.systemVersion }

    /// "{model} — {systemName} {systemVersion}" — used inside the forensic Environment block.
    private static var deviceLine: String { "\(deviceModel) — \(systemName) \(systemVersion)" }

    private static var viewportSize: String {
        let size = UIScreen.main.bounds.size
        return "\(roundedInt(size.width))×\(roundedInt(size.height)) pt"
    }

    private static var screenScale: String {
        let scale = UIScreen.main.scale
        return scale == scale.rounded() ? "\(Int(scale))" : "\(scale)"
    }

    /// "{W}×{H} pt — {model} {systemName} {systemVersion}" — the standard/detailed Viewport line.
    private static var viewportLine: String { "\(viewportSize) — \(deviceModel) \(systemName) \(systemVersion)" }

    private static let footer = #"To locate each element in code: grep the labels and nearby texts above (`Text("…")`, `Label("…")`, accessibility identifiers). Displayed labels may be localized — if a literal doesn't appear in the source, search the app's String Catalog / .lproj files first to find the key."#

    // MARK: - Helpers

    private static func roundedInt(_ value: Double) -> Int { Int(value.rounded()) }

    private static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "..." : text
    }
}
#endif
