//
//  AnnotationCapture.swift
//
//  What lives under a tap: the most relevant accessibility element, neighbouring
//  labels, the UIKit view chain, a probable screen title and a marked screenshot.
//  The accessibility tree is the iOS equivalent of the DOM a web annotation tool
//  would inspect — it carries the semantics (labels, roles) SwiftUI view internals
//  don't expose at runtime.
//

#if DEBUG
import UIKit

@MainActor
enum AnnotationCapture {

    struct Result {
        var annotation: Annotation
        var screenshot: UIImage?
    }

    /// `screenPoint` is in screen coordinates (the space `accessibilityFrame` uses).
    static func capture(atScreenPoint screenPoint: CGPoint, in window: UIWindow) -> Result {
        var annotation = Annotation()
        annotation.tapPoint = screenPoint
        annotation.screenSize = window.screen.bounds.size

        let elements = collectAccessibilityElements(in: window)
        if let hit = bestElement(for: screenPoint, in: elements) {
            annotation.elementLabel = hit.label
            annotation.elementIdentifier = hit.identifier
            annotation.elementValue = hit.value
            annotation.elementType = typeName(for: hit)
            annotation.elementTraits = traitNames(of: hit.traits)
            annotation.elementFrame = hit.frame
        }
        annotation.nearbyTexts = nearbyTexts(around: screenPoint, in: elements, excluding: annotation.elementLabel)

        let windowPoint = window.screen.coordinateSpace.convert(screenPoint, to: window.coordinateSpace)
        annotation.viewChain = viewChain(atWindowPoint: windowPoint, in: window)
        annotation.screenHint = screenHint(in: window, elements: elements)

        return Result(annotation: annotation, screenshot: snapshot(window: window, markAt: windowPoint))
    }

    // MARK: - Accessibility tree

    private struct ElementInfo {
        var frame: CGRect // screen coordinates
        var label: String?
        var identifier: String?
        var value: String?
        var traits: UIAccessibilityTraits
        var className: String
    }

    private static func collectAccessibilityElements(in root: UIView) -> [ElementInfo] {
        var result: [ElementInfo] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                guard !view.isHidden, view.alpha > 0.01 else { return }
            }
            if object.isAccessibilityElement {
                result.append(info(from: object))
            }
            for child in object.accessibilityElements ?? [] {
                if let element = child as? NSObject { visit(element) }
            }
            if let view = object as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }

        visit(root)
        return result
    }

    private static func info(from object: NSObject) -> ElementInfo {
        ElementInfo(
            frame: object.accessibilityFrame,
            label: object.accessibilityLabel,
            identifier: (object as? UIAccessibilityIdentification)?.accessibilityIdentifier,
            value: object.accessibilityValue,
            traits: object.accessibilityTraits,
            className: String(describing: type(of: object))
        )
    }

    /// The element under the finger (smallest one containing the point), otherwise
    /// the closest one within 44 pt — the size of a touch target.
    private static func bestElement(for point: CGPoint, in elements: [ElementInfo]) -> ElementInfo? {
        let containing = elements.filter { !$0.frame.isEmpty && $0.frame.contains(point) }
        if let smallest = containing.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return smallest
        }
        return elements
            .map { (element: $0, distance: distance(from: point, to: $0.frame)) }
            .filter { $0.distance < 44 }
            .min { $0.distance < $1.distance }?
            .element
    }

    private static func nearbyTexts(around point: CGPoint, in elements: [ElementInfo], excluding excluded: String?) -> [String] {
        var seen = Set<String>()
        return elements
            .compactMap { element -> (label: String, distance: CGFloat)? in
                guard let label = element.label, !label.isEmpty, label != excluded else { return nil }
                return (String(label.prefix(80)), distance(from: point, to: element.frame))
            }
            .filter { $0.distance < 120 }
            .sorted { $0.distance < $1.distance }
            .compactMap { seen.insert($0.label).inserted ? $0.label : nil }
            .prefix(6)
            .map { $0 }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        guard !rect.isEmpty else { return .greatestFiniteMagnitude }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func typeName(for element: ElementInfo) -> String {
        let traits = element.traits
        if traits.contains(.button) { return "Button" }
        if traits.contains(.link) { return "Link" }
        if traits.contains(.header) { return "Header" }
        if traits.contains(.searchField) { return "Search field" }
        if traits.contains(.adjustable) { return "Adjustable control" }
        if traits.contains(.image) { return "Image" }
        if element.className.contains("TextField") || element.className.contains("TextView") { return "Text input" }
        if element.className.contains("Switch") { return "Switch" }
        if traits.contains(.staticText) { return "Text" }
        return "Element"
    }

    private static func traitNames(of traits: UIAccessibilityTraits) -> [String] {
        let known: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"),
            (.searchField, "searchField"), (.image, "image"), (.staticText, "staticText"),
            (.adjustable, "adjustable"), (.selected, "selected"), (.notEnabled, "disabled"),
            (.toggleButton, "toggle"), (.keyboardKey, "keyboardKey"), (.tabBar, "tabBar")
        ]
        return known.compactMap { traits.contains($0.0) ? $0.1 : nil }
    }

    // MARK: - UIKit hierarchy

    private static func viewChain(atWindowPoint point: CGPoint, in window: UIWindow) -> [String] {
        var current: UIView = window
        var localPoint = point
        var descending = true
        while descending {
            descending = false
            for subview in current.subviews.reversed() {
                guard !subview.isHidden, subview.alpha > 0.01 else { continue }
                let converted = current.convert(localPoint, to: subview)
                if subview.point(inside: converted, with: nil) {
                    current = subview
                    localPoint = converted
                    descending = true
                    break
                }
            }
        }
        return sequence(first: current, next: { $0.superview })
            .prefix(6)
            .map { String(describing: type(of: $0)) }
    }

    // MARK: - Screen

    private static func screenHint(in window: UIWindow, elements: [ElementInfo]) -> String {
        if let navBar = firstNavigationBar(in: window),
           let title = navBar.topItem?.title, !title.isEmpty {
            return title
        }
        // The topmost accessibility "header" usually is the SwiftUI screen title.
        if let header = elements
            .filter({ $0.traits.contains(.header) && $0.label?.isEmpty == false })
            .min(by: { $0.frame.minY < $1.frame.minY })?
            .label {
            return header
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top.map { String(describing: type(of: $0)) } ?? "Unknown screen"
    }

    private static func firstNavigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar, !bar.isHidden { return bar }
        for subview in view.subviews {
            if let bar = firstNavigationBar(in: subview) { return bar }
        }
        return nil
    }

    // MARK: - Screenshot

    private static func snapshot(window: UIWindow, markAt point: CGPoint) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            let ring = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
            context.cgContext.setStrokeColor(UIColor.systemRed.cgColor)
            context.cgContext.setLineWidth(3)
            context.cgContext.strokeEllipse(in: ring)
            context.cgContext.setFillColor(UIColor.systemRed.withAlphaComponent(0.35).cgColor)
            context.cgContext.fillEllipse(in: ring.insetBy(dx: 12, dy: 12))
        }
    }
}
#endif
