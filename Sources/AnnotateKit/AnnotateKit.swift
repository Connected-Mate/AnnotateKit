//
//  AnnotateKit.swift
//
//  Public API. Everything else in the package is compiled only in Debug builds;
//  in Release these entry points compile to no-ops so you can leave the modifier
//  in place permanently, like a dev-only npm dependency.
//

import SwiftUI

public enum AnnotateKit {

    #if DEBUG
    @MainActor
    struct Configuration {
        var appGroupIdentifier: String?
        var logSubsystem: String?
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
    @MainActor
    public static func configure(appGroupIdentifier: String? = nil, logSubsystem: String? = nil) {
        #if DEBUG
        configuration = Configuration(
            appGroupIdentifier: appGroupIdentifier,
            logSubsystem: logSubsystem
        )
        #endif
    }
}

public extension View {
    /// Installs the AnnotateKit overlay (floating pill + annotation mode) on this
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
