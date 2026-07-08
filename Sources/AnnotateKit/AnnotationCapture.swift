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
import Darwin
import UIKit

@MainActor
enum AnnotationCapture {

    /// SwiftUI only materialises its accessibility tree when an assistive client
    /// is connected. Flip the same switch UI-testing and AccessibilitySnapshot
    /// use so the tree exists when we walk it. Debug builds only — this never
    /// ships. Returns false (and capture falls back to the UIKit view chain)
    /// if the toggle isn't available.
    private static let accessibilityActivated: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return false }
        guard let symbol = dlsym(handle, "AXSSetAutomationEnabled")
            ?? dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(1)
        return true
    }()

    /// Call early (overlay install) so the tree is built before the first capture.
    static func activateAccessibility() {
        _ = accessibilityActivated
    }

    struct Result {
        var annotation: Annotation
        var screenshot: UIImage?
    }

    /// Lightweight hit info for the hover/tap highlight.
    struct Probe {
        var frameInScreen: CGRect
        var title: String
    }

    /// What lives under a point — used live, while hovering, before any tap.
    static func probe(atScreenPoint point: CGPoint, in window: UIWindow) -> Probe? {
        let elements = collectAccessibilityElements(in: window)
        guard let hit = bestElement(for: point, in: elements) else { return nil }
        let name = hit.label?.nilIfEmpty ?? hit.identifier?.nilIfEmpty ?? hit.className
        return Probe(
            frameInScreen: hit.frame,
            title: "\(typeName(for: hit)) — \(String(name.prefix(40)))"
        )
    }

    /// `screenPoint` is in screen coordinates (the space `accessibilityFrame` uses).
    /// The screenshot is taken here, at tap time — before any popup opens and
    /// before the app underneath can animate away from what the user pointed at.
    static func capture(atScreenPoint screenPoint: CGPoint, in window: UIWindow) -> Result {
        capture(atScreenPoint: screenPoint, in: window, elements: collectAccessibilityElements(in: window))
    }

    private static func capture(
        atScreenPoint screenPoint: CGPoint, in window: UIWindow, elements: [ElementInfo]
    ) -> Result {
        var annotation = Annotation()
        let windowPoint = window.screen.coordinateSpace.convert(screenPoint, to: window.coordinateSpace)
        let size = window.bounds.size
        annotation.x = size.width > 0 ? (windowPoint.x / size.width) * 100 : 0
        annotation.y = windowPoint.y
        annotation.url = "ios://\(Bundle.main.bundleIdentifier ?? "app")"

        var hitLabel: String?
        if let hit = bestElement(for: screenPoint, in: elements) {
            apply(hit, to: &annotation, in: window)
            hitLabel = hit.label
        }
        annotation.nearbyText = nearbyTexts(around: screenPoint, in: elements, excluding: hitLabel)
            .joined(separator: " · ").nilIfEmpty
        annotation.nearbyElements = nearbyElementDescriptions(around: screenPoint, in: elements)
            .joined(separator: ", ").nilIfEmpty

        annotation.windowRegion = regionDescription(point: windowPoint, in: size)
        let chain = viewChain(atWindowPoint: windowPoint, in: window)
        annotation.viewChain = chain.map(\.className)
        annotation.cssClasses = chain.first?.className
        annotation.fullPath = chain.reversed().map(\.className).joined(separator: " > ")
        annotation.computedStyles = computedStyles(of: chain.first?.view)
        annotation.isFixed = isFixed(chain: annotation.viewChain) ? true : nil
        annotation.screenHint = screenHint(in: window, elements: elements)
        if annotation.elementPath.isEmpty { annotation.elementPath = annotation.fullPath ?? "" }

        return Result(annotation: annotation, screenshot: rawSnapshot(of: window))
    }

    /// Every accessibility element intersecting `screenRect` — the drag-rectangle
    /// multi-select, like Agentation's shift-drag.
    static func captureMulti(inScreenRect screenRect: CGRect, in window: UIWindow) -> Result? {
        let elements = collectAccessibilityElements(in: window)
        let hits = elements
            .filter { !$0.frame.isEmpty && $0.frame.intersects(screenRect) }
            .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        guard !hits.isEmpty else { return nil }

        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        var result = capture(atScreenPoint: center, in: window, elements: elements)
        var annotation = result.annotation
        annotation.isMultiSelect = true
        annotation.element = "\(hits.count) elements"
        annotation.elementBoundingBoxes = hits.map { hit in
            Box(window.screen.coordinateSpace.convert(hit.frame, to: window.coordinateSpace))
        }
        let windowRect = window.screen.coordinateSpace.convert(screenRect, to: window.coordinateSpace)
        annotation.boundingBox = Box(windowRect)
        annotation.selectedText = hits.compactMap(\.label).filter { !$0.isEmpty }
            .prefix(8).joined(separator: " · ").nilIfEmpty
        annotation.elementPath = hits.compactMap { name(of: $0) }.prefix(8).joined(separator: ", ")
        result.annotation = annotation
        return result
    }

    private static func apply(_ hit: ElementInfo, to annotation: inout Annotation, in window: UIWindow) {
        var element = typeName(for: hit)
        if let label = hit.label, !label.isEmpty { element += " “\(label)”" }
        annotation.element = element
        annotation.elementIdentifier = hit.identifier?.nilIfEmpty
        annotation.elementValue = hit.value?.nilIfEmpty
        annotation.elementTraits = traitNames(of: hit.traits)
        let windowFrame = window.screen.coordinateSpace.convert(hit.frame, to: window.coordinateSpace)
        annotation.boundingBox = Box(windowFrame)
        // The iOS analogue of a CSS selector path: screen → type → label/id.
        var path: [String] = []
        if let id = hit.identifier, !id.isEmpty { path.append("#\(id)") }
        else if let label = hit.label, !label.isEmpty { path.append("“\(label)”") }
        annotation.elementPath = "\(typeName(for: hit))\(path.isEmpty ? "" : " ")\(path.joined())"
        annotation.accessibility = accessibilityDescription(of: hit)
        // If the tapped element is text-like, carry its content — Agentation's
        // selected-text capture, minus the manual selection.
        if hit.traits.contains(.staticText), let label = hit.label, !label.isEmpty {
            annotation.selectedText = label
        }
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
        _ = accessibilityActivated
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
            if let children = object.accessibilityElements {
                for child in children {
                    if let element = child as? NSObject { visit(element) }
                }
            } else {
                // SwiftUI hosting views expose their tree through the container
                // protocol, not the array property — this is where the labels are.
                let count = object.accessibilityElementCount()
                if count > 0 && count != NSNotFound {
                    for index in 0..<min(count, 300) {
                        if let element = object.accessibilityElement(at: index) as? NSObject {
                            visit(element)
                        }
                    }
                }
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

    private static func nearbyElementDescriptions(around point: CGPoint, in elements: [ElementInfo]) -> [String] {
        elements
            .map { (element: $0, distance: distance(from: point, to: $0.frame)) }
            .filter { $0.distance > 0 && $0.distance < 120 }
            .sorted { $0.distance < $1.distance }
            .prefix(5)
            .compactMap { name(of: $0.element) }
    }

    private static func name(of element: ElementInfo) -> String? {
        guard let label = element.label ?? element.identifier, !label.isEmpty else { return nil }
        return "\(typeName(for: element)) “\(String(label.prefix(40)))”"
    }

    private static func accessibilityDescription(of element: ElementInfo) -> String {
        var parts: [String] = []
        if let label = element.label, !label.isEmpty { parts.append("label: “\(label)”") }
        if let id = element.identifier, !id.isEmpty { parts.append("identifier: \(id)") }
        if let value = element.value, !value.isEmpty { parts.append("value: “\(value)”") }
        let traits = traitNames(of: element.traits)
        if !traits.isEmpty { parts.append("traits: \(traits.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    /// Human placement inside the window ("bottom-right", "middle-center"…).
    private static func regionDescription(point: CGPoint, in size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "unknown" }
        let column = ["left", "center", "right"][max(0, min(2, Int(point.x / (size.width / 3))))]
        let row = ["top", "middle", "bottom"][max(0, min(2, Int(point.y / (size.height / 3))))]
        return "\(row)-\(column)"
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

    private struct ChainEntry {
        var view: UIView
        var className: String
    }

    private static func viewChain(atWindowPoint point: CGPoint, in window: UIWindow) -> [ChainEntry] {
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
            .map { ChainEntry(view: $0, className: String(describing: type(of: $0))) }
    }

    /// The iOS "computed styles": what the deepest UIKit view under the tap can tell.
    private static func computedStyles(of view: UIView?) -> String? {
        guard let view else { return nil }
        var parts: [String] = []
        if let label = view as? UILabel {
            parts.append("font: \(label.font.fontName) \(Int(label.font.pointSize))pt")
            parts.append("color: \(hex(label.textColor))")
        } else if let field = view as? UITextField, let font = field.font {
            parts.append("font: \(font.fontName) \(Int(font.pointSize))pt")
        }
        if let bg = view.backgroundColor, bg != .clear { parts.append("background: \(hex(bg))") }
        if view.layer.cornerRadius > 0 { parts.append("corner-radius: \(Int(view.layer.cornerRadius))pt") }
        if view.alpha < 1 { parts.append("alpha: \(String(format: "%.2f", view.alpha))") }
        parts.append("size: \(Int(view.bounds.width))×\(Int(view.bounds.height))pt")
        return parts.joined(separator: "; ")
    }

    private static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Nav bars, tab bars and toolbars are the iOS equivalent of position:fixed.
    private static func isFixed(chain: [String]) -> Bool {
        chain.contains { $0.contains("UINavigationBar") || $0.contains("UITabBar") || $0.contains("UIToolbar") }
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

    /// Plain snapshot of the window, no overlays — taken at tap time.
    static func rawSnapshot(of window: UIWindow) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Draws the Agentation-style numbered marker (and multi-select boxes /
    /// strokes) onto the tap-time snapshot. Coordinates are window points, the
    /// space the base image was rendered in.
    static func mark(base: UIImage, bounds: CGRect, annotation: Annotation, number: Int, accent: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            base.draw(in: bounds)
            let cg = context.cgContext

            if let boxes = annotation.elementBoundingBoxes, annotation.isMultiSelect == true {
                cg.setStrokeColor(accent.cgColor)
                cg.setLineWidth(2)
                for box in boxes { cg.stroke(box.rect.insetBy(dx: -2, dy: -2)) }
            } else if let box = annotation.boundingBox {
                cg.setStrokeColor(accent.cgColor)
                cg.setLineWidth(2)
                cg.stroke(box.rect.insetBy(dx: -2, dy: -2))
            }

            if let strokes = annotation.strokes {
                cg.setStrokeColor(accent.cgColor)
                cg.setLineWidth(3)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                for stroke in strokes where stroke.count > 1 {
                    cg.beginPath()
                    cg.move(to: CGPoint(x: stroke[0][0], y: stroke[0][1]))
                    for point in stroke.dropFirst() {
                        cg.addLine(to: CGPoint(x: point[0], y: point[1]))
                    }
                    cg.strokePath()
                }
            }

            let point = CGPoint(x: annotation.x / 100 * bounds.width, y: annotation.y)
            let size = AnnotationTheme.markerSize
            let circle = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            cg.setFillColor(accent.cgColor)
            cg.fillEllipse(in: circle)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: circle)

            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
