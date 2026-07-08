//
//  AnnotationFreeze.swift
//
//  Pause / resume every Core Animation in the app's windows — the iOS take on
//  Agentation's "freeze animations": stop the UI on the exact frame you want to
//  annotate, capture, then let it run again.
//
//  Freezing a layer tree is done at the root: setting `speed = 0` after anchoring
//  `timeOffset` to the current media time halts all descendant animations on their
//  current frame. Resuming re-derives `beginTime` so animations continue from the
//  frame they were paused on instead of jumping ahead.
//

#if DEBUG
import UIKit

@MainActor
enum AnnotationFreeze {

    private(set) static var isFrozen = false
    private static var frozenLayers: [CALayer] = []

    /// Freeze every window of the scene except the overlay's own window.
    static func freeze(scene: UIWindowScene, excluding overlayWindow: UIWindow?) {
        guard !isFrozen else { return }
        for window in scene.windows where window !== overlayWindow && !window.isHidden {
            pause(window.layer)
            frozenLayers.append(window.layer)
        }
        isFrozen = !frozenLayers.isEmpty
    }

    static func unfreeze() {
        frozenLayers.forEach(resume)
        frozenLayers.removeAll()
        isFrozen = false
    }

    private static func pause(_ layer: CALayer) {
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    private static func resume(_ layer: CALayer) {
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        layer.beginTime = timeSincePause
    }
}
#endif
