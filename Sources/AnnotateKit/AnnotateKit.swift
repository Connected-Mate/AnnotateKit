//
//  AnnotateKit.swift
//
//  Public API. Everything else in the package is compiled only in Debug builds;
//  in Release these entry points compile to no-ops so you can leave the modifier
//  in place permanently, like a dev-only npm dependency.
//

import SwiftUI

/// Lifecycle callbacks, mirroring Agentation's component props
/// (`onAnnotationAdd`, `onAnnotationDelete`, `onCopy`, `onSubmit`…).
/// Annotation payloads are delivered as JSON strings in the published schema.
public struct AnnotateKitCallbacks: Sendable {
    public var onAnnotationAdd: (@MainActor @Sendable (String) -> Void)?
    public var onAnnotationUpdate: (@MainActor @Sendable (String) -> Void)?
    /// Receives the deleted annotation as JSON (same schema as the other callbacks).
    public var onAnnotationDelete: (@MainActor @Sendable (String) -> Void)?
    public var onAnnotationClear: (@MainActor @Sendable () -> Void)?
    /// Receives the generated markdown whenever the user copies it.
    public var onCopy: (@MainActor @Sendable (String) -> Void)?
    /// Receives the generated markdown whenever the user sends (webhook / server action).
    public var onSubmit: (@MainActor @Sendable (String) -> Void)?

    public init(
        onAnnotationAdd: (@MainActor @Sendable (String) -> Void)? = nil,
        onAnnotationUpdate: (@MainActor @Sendable (String) -> Void)? = nil,
        onAnnotationDelete: (@MainActor @Sendable (String) -> Void)? = nil,
        onAnnotationClear: (@MainActor @Sendable () -> Void)? = nil,
        onCopy: (@MainActor @Sendable (String) -> Void)? = nil,
        onSubmit: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.onAnnotationAdd = onAnnotationAdd
        self.onAnnotationUpdate = onAnnotationUpdate
        self.onAnnotationDelete = onAnnotationDelete
        self.onAnnotationClear = onAnnotationClear
        self.onCopy = onCopy
        self.onSubmit = onSubmit
    }
}

public enum AnnotateKit {

    #if DEBUG
    @MainActor
    struct Configuration {
        var appGroupIdentifier: String?
        var logSubsystem: String?
        var endpoint: URL?
        var webhookURL: URL?
        var callbacks = AnnotateKitCallbacks()
    }

    @MainActor
    static var configuration = Configuration()
    #endif

    /// Optional. Call once, before the first view using `.annotationOverlay()` appears
    /// (e.g. in your `App.init`).
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: store annotation files in this App Group container
    ///     instead of the app's Documents directory. Useful with Mac Catalyst, where
    ///     the group container is a plain folder an agent on the Mac can read directly.
    ///   - logSubsystem: OSLog subsystem for the one-line JSON emitted per annotation
    ///     (category is always `AnnotateKit`). Defaults to the main bundle identifier.
    ///   - endpoint: an `agentation-mcp` server to sync with in real time
    ///     (e.g. `http://192.168.1.20:4747` — your Mac, running `npx agentation-mcp server`).
    ///     Annotations appear to MCP-connected agents without any copy-paste.
    ///   - webhookURL: POST the generated output to this URL when the user hits Send.
    ///   - callbacks: lifecycle hooks (add / update / delete / clear / copy / submit).
    @MainActor
    public static func configure(
        appGroupIdentifier: String? = nil,
        logSubsystem: String? = nil,
        endpoint: URL? = nil,
        webhookURL: URL? = nil,
        callbacks: AnnotateKitCallbacks = AnnotateKitCallbacks()
    ) {
        #if DEBUG
        configuration = Configuration(
            appGroupIdentifier: appGroupIdentifier,
            logSubsystem: logSubsystem,
            endpoint: endpoint,
            webhookURL: webhookURL,
            callbacks: callbacks
        )
        #endif
    }

    /// Generated markdown for the current annotations (empty string in Release).
    @MainActor
    public static func output() -> String {
        #if DEBUG
        return AnnotationOverlayController.shared.store.markdownPrompt()
        #else
        return ""
        #endif
    }

    /// All annotations as a JSON array string in the published schema ("[]" in Release).
    @MainActor
    public static func annotationsJSON() -> String {
        #if DEBUG
        let cleaned = AnnotationOverlayController.shared.store.annotations.map { annotation in
            var copy = annotation
            copy._syncedTo = nil
            return copy
        }
        guard let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
        #else
        return "[]"
        #endif
    }

    /// Remove every annotation (no-op in Release).
    @MainActor
    public static func clearAll() {
        #if DEBUG
        AnnotationOverlayController.shared.store.clear()
        #endif
    }
}

public extension View {
    /// Installs the AnnotateKit overlay (floating toolbar + annotation mode) on this
    /// view's window scene. Attach it once, near the root of your app.
    ///
    /// Debug builds only — in Release this modifier is an inert `self`, so no debug
    /// UI, files, or logs can ever ship to TestFlight / the App Store.
    @ViewBuilder
    func annotationOverlay() -> some View {
        #if DEBUG
        background(AnnotationSceneGrabber().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}
