//
//  AnnotationOverlay.swift
//
//  Passthrough window above the app (the classic debug-tool pattern, à la FLEX):
//  floating toolbar → annotation mode → tap captured → note → prompt export. The
//  window only eats touches while the tool is in use; the rest of the time the
//  app behaves as if it weren't there.
//

#if DEBUG
import Combine
import SwiftUI
import UIKit

// MARK: - Controller

@MainActor
final class AnnotationOverlayController: ObservableObject {
    static let shared = AnnotationOverlayController()

    enum SendState: Equatable { case idle, sending, sent, error }

    @Published var isAnnotating = false {
        didSet {
            if isAnnotating {
                // Key status routes hardware-keyboard shortcuts (P/L/H/C/X/S/Esc)
                // to the overlay while the tool is active.
                overlayWindow?.makeKey()
            } else {
                exitSubModes()
                restoreMainKeyWindow()
            }
        }
    }
    @Published var isFrozen = false
    @Published var isDrawMode = false
    @Published var isLayoutMode = false
    @Published var markersVisible = true
    @Published var isHiddenTemporarily = false
    @Published var draft: AnnotationDraft?
    @Published var showSettings = false
    @Published var showList = false
    @Published var confirmClearAll = false
    @Published var sendState: SendState = .idle
    @Published var copied = false

    lazy var store = AnnotationStore()
    lazy var sync = AnnotationSync.shared
    let anchorTracker = MarkerAnchorTracker()

    /// Toolbar frame (window coordinates) — the only interactive zone when idle.
    var toolbarFrame: CGRect = .zero
    /// Marker frames by annotation id — interactive when markers are shown.
    var markerFrames: [String: CGRect] = [:]

    private var overlayWindow: AnnotationWindow?

    func install(in scene: UIWindowScene) {
        guard overlayWindow == nil else { return }
        let window = AnnotationWindow(windowScene: scene)
        window.controller = self
        window.windowLevel = .alert + 100
        window.backgroundColor = .clear
        let hosting = UIHostingController(rootView: AnnotationOverlayRoot(controller: self, store: store))
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        window.isHidden = false
        overlayWindow = window
        AnnotationCapture.activateAccessibility()
        sync.start(store: store)
        anchorTracker.start(controller: self)

        // Returning from the background occasionally leaves the overlay stale
        // (hidden window or an out-of-date toolbar hit-frame → the circle stops
        // responding). Re-assert visibility and force a layout pass so every
        // FrameReporter republishes fresh frames.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterForeground() }
        }
    }

    private func refreshAfterForeground() {
        guard let window = overlayWindow else { return }
        window.isHidden = false
        window.windowLevel = .alert + 100
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
    }

    /// The app window under the overlay: what we screenshot and hit-test.
    func mainWindow() -> UIWindow? {
        guard let scene = overlayWindow?.windowScene else { return nil }
        let candidates = scene.windows.filter { $0 !== overlayWindow && !$0.isHidden }
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    func captureTap(atWindowPoint point: CGPoint) {
        guard let overlayWindow, let main = mainWindow() else { return }
        let screenPoint = overlayWindow.coordinateSpace.convert(point, to: overlayWindow.screen.coordinateSpace)
        let result = AnnotationCapture.capture(atScreenPoint: screenPoint, in: main)
        let chain = AnnotationCapture.hierarchy(atScreenPoint: screenPoint, in: main)
        draft = AnnotationDraft(
            annotation: result.annotation, isNew: true, screenshot: result.screenshot, hierarchy: chain
        )
    }

    /// Popup level stepper: re-target the draft at another link of the
    /// containment chain (0 = leaf, up = containing card/section).
    func setDraftLevel(_ index: Int) {
        guard var draft = draft, draft.hierarchy.indices.contains(index),
              let main = mainWindow() else { return }
        var annotation = draft.annotation
        AnnotationCapture.retarget(&annotation, to: draft.hierarchy[index], in: main)
        draft.annotation = annotation
        draft.level = index
        self.draft = draft
    }

    func captureMulti(windowRect: CGRect) {
        guard let overlayWindow, let main = mainWindow() else { return }
        let screenRect = overlayWindow.coordinateSpace.convert(windowRect, to: overlayWindow.screen.coordinateSpace)
        guard let result = AnnotationCapture.captureMulti(inScreenRect: screenRect, in: main) else { return }
        draft = AnnotationDraft(annotation: result.annotation, isNew: true, screenshot: result.screenshot)
    }

    /// Live hit info for the hover highlight, in the overlay window's coordinates.
    func probe(atWindowPoint point: CGPoint) -> AnnotationCapture.Probe? {
        guard let overlayWindow, let main = mainWindow() else { return nil }
        let screenPoint = overlayWindow.coordinateSpace.convert(point, to: overlayWindow.screen.coordinateSpace)
        return AnnotationCapture.probe(atScreenPoint: screenPoint, in: main)
    }

    func saveDraft(_ annotation: Annotation, isNew: Bool) {
        if isNew {
            let number = store.annotations.count + 1
            // Marker burned onto the tap-time snapshot: the screenshot shows what
            // the user actually pointed at, not the screen as it is after typing
            // the note (fallback: snapshot now).
            let bounds = mainWindow()?.bounds ?? UIScreen.main.bounds
            let base = draft?.screenshot ?? mainWindow().flatMap(AnnotationCapture.rawSnapshot(of:))
            let screenshot = base.map {
                AnnotationCapture.mark(
                    base: $0,
                    bounds: bounds,
                    annotation: annotation,
                    number: number,
                    accent: store.settings.accent.uiColor
                )
            }
            store.add(annotation, screenshot: screenshot)
        } else {
            store.update(annotation)
        }
        draft = nil
    }

    func markerTapped(_ annotation: Annotation) {
        switch store.settings.markerClickBehavior {
        case .edit: draft = AnnotationDraft(annotation: annotation, isNew: false)
        case .delete: store.remove(annotation)
        }
    }

    // MARK: Actions (toolbar + keyboard)

    func toggleActive() {
        isAnnotating.toggle()
    }

    func toggleFreeze() {
        guard let scene = overlayWindow?.windowScene else { return }
        if isFrozen {
            AnnotationFreeze.unfreeze()
        } else {
            AnnotationFreeze.freeze(scene: scene, excluding: overlayWindow)
        }
        isFrozen = AnnotationFreeze.isFrozen
    }

    func copyOutput() {
        guard !store.annotations.isEmpty else { return }
        let output = store.markdownPrompt()
        UIPasteboard.general.string = output
        AnnotateKit.configuration.callbacks.onCopy?(output)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// Destructive and propagated to the server — always confirmed first,
    /// keyboard shortcut included.
    func requestClearAll() {
        guard !store.annotations.isEmpty else { return }
        confirmClearAll = true
    }

    func clearAll() {
        store.clear()
        markerFrames.removeAll()
    }

    /// Somewhere for Send to go: a sync server, or a plain webhook URL.
    var hasSendTarget: Bool {
        !store.settings.endpoint.isEmpty
            || URL(string: store.settings.webhookURL)?.scheme?.hasPrefix("http") == true
    }

    /// Send: server action when an endpoint session exists, direct webhook otherwise.
    func send() {
        guard sendState == .idle, !store.annotations.isEmpty, hasSendTarget else { return }
        let output = store.markdownPrompt()
        let webhook = store.settings.webhookURL
        let hasEndpoint = !store.settings.endpoint.isEmpty
        sendState = .sending
        AnnotateKit.configuration.callbacks.onSubmit?(output)
        Task { @MainActor in
            var ok = false
            if hasEndpoint {
                ok = await sync.sendAction(output: output)
            }
            if !ok, URL(string: webhook)?.scheme?.hasPrefix("http") == true {
                ok = await sync.fireWebhook(urlString: webhook, annotations: store.annotations, output: output)
            }
            sendState = ok ? .sent : .error
            try? await Task.sleep(for: .seconds(2))
            sendState = .idle
        }
    }

    func hideTemporarily() {
        // Until the next launch — the counterpart of Agentation's per-tab hide.
        isHiddenTemporarily = true
        showSettings = false
        isAnnotating = false
    }

    private func exitSubModes() {
        isDrawMode = false
        isLayoutMode = false
        if isFrozen { toggleFreeze() }
    }

    /// Escape cascade, same order as the web tool.
    func escape() {
        if isLayoutMode { isLayoutMode = false }
        else if isDrawMode { isDrawMode = false }
        else if draft != nil { draft = nil }
        else if showSettings { showSettings = false }
        else if isAnnotating { isAnnotating = false }
    }

    /// Presenting our sheets makes the overlay window key; hand key status back so
    /// the app's own text fields keep their keyboard afterwards.
    func restoreMainKeyWindow() {
        mainWindow()?.makeKey()
    }
}

struct AnnotationDraft: Identifiable {
    var id: String { annotation.id }
    var annotation: Annotation
    var isNew: Bool
    /// Raw snapshot taken when the element was tapped — markers get drawn onto
    /// it at save time.
    var screenshot: UIImage?
    /// Containment chain under the tap (leaf first) — the popup's level stepper.
    var hierarchy: [AnnotationCapture.ElementInfo] = []
    var level = 0
}

// MARK: - Window (hit-testing + keyboard shortcuts)

/// Only opaque to touches while the tool is in use.
///
/// The pass-through decision is made purely from state + UIKit frames — never by
/// comparing `super.hitTest`'s result to the root view. SwiftUI controls don't
/// create dedicated UIViews, so a click on the toolbar legitimately resolves to
/// the hosting view itself; an identity check would swallow it.
final class AnnotationWindow: UIWindow {
    weak var controller: AnnotationOverlayController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller, !controller.isHiddenTemporarily else { return nil }
        let interactive = controller.isAnnotating
            || controller.draft != nil
            || controller.showSettings
            || rootViewController?.presentedViewController != nil
            || controller.toolbarFrame.insetBy(dx: -12, dy: -12).contains(point)
            || (controller.markersVisible
                && controller.markerFrames.values.contains { $0.insetBy(dx: -6, dy: -6).contains(point) })
        guard interactive else { return nil }
        return super.hitTest(point, with: event)
    }

    // Same bindings as the web tool: ⌘⇧F toggle, P freeze, L layout, H markers,
    // C copy, X clear, S send, Esc cascade. Plain letters only fire when no text
    // field has focus (text input keeps priority).
    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "f", modifierFlags: [.command, .shift], action: #selector(kbToggle)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(kbEscape))
        ]
        let plain: [(String, Selector)] = [
            ("p", #selector(kbFreeze)), ("l", #selector(kbLayout)), ("h", #selector(kbMarkers)),
            ("c", #selector(kbCopy)), ("x", #selector(kbClear)), ("s", #selector(kbSend))
        ]
        commands += plain.map { UIKeyCommand(input: $0.0, modifierFlags: [], action: $0.1) }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let kb: Set<Selector> = [
            #selector(kbToggle), #selector(kbEscape), #selector(kbFreeze), #selector(kbLayout),
            #selector(kbMarkers), #selector(kbCopy), #selector(kbClear), #selector(kbSend)
        ]
        if kb.contains(action) { return controller != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func kbToggle() { controller?.toggleActive() }
    @objc private func kbEscape() { controller?.escape() }
    @objc private func kbFreeze() { controller?.toggleFreeze() }
    @objc private func kbLayout() { controller?.isLayoutMode.toggle() }
    @objc private func kbMarkers() { controller?.markersVisible.toggle() }
    @objc private func kbCopy() { controller?.copyOutput() }
    @objc private func kbClear() { controller?.requestClearAll() }
    @objc private func kbSend() { controller?.send() }
}

// MARK: - Overlay root

struct AnnotationOverlayRoot: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore

    var body: some View {
        ZStack {
            if !controller.isHiddenTemporarily {
                if controller.isAnnotating && controller.draft == nil {
                    captureLayer
                }
                if controller.markersVisible {
                    // Empty space in the layer is never hit — the window's hitTest
                    // only lets touches through on the marker frames themselves.
                    AnnotationMarkersLayer(
                        controller: controller, store: store, tracker: controller.anchorTracker
                    )
                }
                AnnotationToolbar(controller: controller, store: store)
                if let draft = controller.draft {
                    AnnotationPopupHost(controller: controller, store: store, draft: draft)
                }
                if controller.showSettings {
                    AnnotationSettingsHost(controller: controller, store: store)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .sheet(isPresented: $controller.showList) {
            AnnotationListSheet(controller: controller, store: store)
                .onDisappear { controller.restoreMainKeyWindow() }
        }
        .confirmationDialog(
            "Delete all annotations?",
            isPresented: $controller.confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) { controller.clearAll() }
        }
        // Root-level (always mounted, unlike the markers layer): drop hit-frames of
        // annotations that no longer exist, whatever path deleted them.
        .onChange(of: store.annotations.map(\.id)) { _, ids in
            controller.markerFrames = controller.markerFrames.filter { ids.contains($0.key) }
        }
    }

    @ViewBuilder
    private var captureLayer: some View {
        if controller.isDrawMode {
            DrawCanvasView { strokes, bounds in
                guard !strokes.isEmpty else { return }
                controller.isDrawMode = false
                makeDrawingDraft(strokes: strokes, bounds: bounds)
            }
            .ignoresSafeArea()
        } else if controller.isLayoutMode {
            LayoutModeView(controller: controller)
                .ignoresSafeArea()
        } else {
            CaptureLayerView(
                accent: store.settings.accent.uiColor
            ) { windowPoint in
                controller.captureTap(atWindowPoint: windowPoint)
            } onDragRect: { rect in
                controller.captureMulti(windowRect: rect)
            } probe: { windowPoint in
                controller.probe(atWindowPoint: windowPoint)
            }
            .ignoresSafeArea()
        }
    }

    private func makeDrawingDraft(strokes: [[CGPoint]], bounds: CGRect) {
        guard let main = controller.mainWindow() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let screenPoint = main.coordinateSpace.convert(center, to: main.screen.coordinateSpace)
        let result = AnnotationCapture.capture(atScreenPoint: screenPoint, in: main)
        var annotation = result.annotation
        annotation.element = "Drawing over \(annotation.element)"
        annotation.strokes = strokes.map { $0.map { [Double($0.x), Double($0.y)] } }
        annotation.boundingBox = Box(bounds)
        controller.draft = AnnotationDraft(annotation: annotation, isNew: true, screenshot: result.screenshot)
    }
}

// MARK: - Markers layer

/// Re-resolves each anchored annotation's element a few times per second so
/// markers follow scrolled content and disappear when their element isn't on
/// screen anymore (tab switch, pushed screen). Annotations without an anchor
/// (drawings, placements, multi-select) keep the static window position.
@MainActor
final class MarkerAnchorTracker: ObservableObject {
    /// id → current window-point, or nil when the element is not on screen.
    /// Absent key = annotation has no anchor (render at the static position).
    @Published private(set) var resolved: [String: CGPoint?] = [:]

    private weak var controller: AnnotationOverlayController?
    private var timer: Timer?

    func start(controller: AnnotationOverlayController) {
        guard timer == nil else { return }
        self.controller = controller
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let controller, controller.markersVisible, !controller.isHiddenTemporarily,
              let main = controller.mainWindow() else { return }
        let anchored = controller.store.annotations.filter {
            $0._anchorId != nil || $0._anchorLabel != nil
        }
        guard !anchored.isEmpty else {
            if !resolved.isEmpty { resolved = [:] }
            return
        }

        let elements = AnnotationCapture.anchorElements(in: main)
        var out: [String: CGPoint?] = [:]
        for annotation in anchored {
            let match = elements.first { element in
                if let id = annotation._anchorId { return element.identifier == id }
                return element.label == annotation._anchorLabel && element.label != nil
            }
            guard let match, !match.frame.isEmpty else {
                out[annotation.id] = CGPoint?.none
                continue
            }
            let windowRect = main.screen.coordinateSpace.convert(match.frame, to: main.coordinateSpace)
            // Same relative offset inside the element as the original tap.
            var point = CGPoint(x: windowRect.midX, y: windowRect.midY)
            if let box = annotation.boundingBox, box.rect.width > 0, box.rect.height > 0 {
                let tapX = annotation.x / 100 * main.bounds.width
                let fx = min(max((tapX - box.rect.minX) / box.rect.width, 0), 1)
                let fy = min(max((annotation.y - box.rect.minY) / box.rect.height, 0), 1)
                point = CGPoint(
                    x: windowRect.minX + fx * windowRect.width,
                    y: windowRect.minY + fy * windowRect.height
                )
            }
            out[annotation.id] = main.bounds.insetBy(dx: -10, dy: -10).contains(point) ? point : CGPoint?.none
        }
        if out != resolved { resolved = out }
    }
}

/// Numbered Agentation-style markers for every saved annotation. Anchored ones
/// track their element live; the rest stay window-anchored.
private struct AnnotationMarkersLayer: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore
    @ObservedObject var tracker: MarkerAnchorTracker

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(store.annotations.enumerated()), id: \.element.id) { index, annotation in
                // Anchored + off-screen → no marker (its element isn't visible).
                if let point = position(for: annotation, in: geo.size) {
                    AnnotationMarker(
                        number: index + 1,
                        annotation: annotation,
                        accent: store.settings.accent.color
                    )
                    // Frame reader + tap BEFORE .position: they must size to the 22 pt
                    // marker itself, not the full-screen positioned wrapper — otherwise
                    // one annotation turns the whole window into a "marker".
                    .background(FrameReporter { frame in
                        controller.markerFrames[annotation.id] = frame
                    })
                    .onTapGesture { controller.markerTapped(annotation) }
                    .position(point)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(AnnotationTheme.markerCurve, value: store.annotations.count)
        // Anchored markers whose element left the screen must also stop being
        // tap targets in the window's hitTest.
        .onChange(of: tracker.resolved) { _, resolved in
            for case let (id, .none) in resolved {
                controller.markerFrames.removeValue(forKey: id)
            }
        }
    }

    private func position(for annotation: Annotation, in size: CGSize) -> CGPoint? {
        if let entry = tracker.resolved[annotation.id] {
            guard let point = entry else { return nil } // anchored, not on screen
            return point
        }
        return CGPoint(
            x: annotation.x / 100 * size.width,
            y: min(max(annotation.y, 14), size.height - 14)
        )
    }
}

private struct AnnotationMarker: View {
    let number: Int
    let annotation: Annotation
    let accent: Color

    var body: some View {
        let multi = annotation.isMultiSelect == true
        let size = multi ? AnnotationTheme.multiSelectMarkerSize : AnnotationTheme.markerSize
        Text("\(number)")
            .font(.system(size: multi ? 12 : 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                accent,
                in: multi
                    ? AnyShape(RoundedRectangle(cornerRadius: AnnotationTheme.multiSelectMarkerRadius))
                    : AnyShape(Circle())
            )
            .overlay {
                if multi {
                    RoundedRectangle(cornerRadius: AnnotationTheme.multiSelectMarkerRadius)
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                } else {
                    Circle().stroke(.white.opacity(0.8), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            .opacity(annotation.status == .acknowledged ? 0.6 : 1)
    }
}

/// Reports a view's frame in window coordinates whenever UIKit moves it — the
/// ground truth AnnotationWindow.hitTest works from (used by both the toolbar
/// and every marker).
struct FrameReporter: UIViewRepresentable {
    var onChange: (CGRect) -> Void

    final class ReporterView: UIView {
        var onChange: ((CGRect) -> Void)?
        override var frame: CGRect { didSet { report() } }
        override var center: CGPoint { didSet { report() } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }
        private func report() {
            guard let window else { return }
            onChange?(convert(bounds, to: window))
        }
    }

    func makeUIView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReporterView, context: Context) {
        uiView.onChange = onChange
    }
}

// MARK: - Capture layer (UIKit)

/// Full-screen UIKit view active in annotation mode: consumes every click/tap,
/// highlights the accessibility element under the pointer (hover, à la Agentation
/// web) or under the finger while dragging (scrub — release to select), and turns
/// long-press-then-drag into a multi-select rectangle.
private struct CaptureLayerView: UIViewRepresentable {
    var accent: UIColor
    var onTap: (CGPoint) -> Void
    var onDragRect: (CGRect) -> Void
    var probe: (CGPoint) -> AnnotationCapture.Probe?

    func makeUIView(context: Context) -> CaptureUIView {
        let view = CaptureUIView()
        view.accent = accent
        view.onTap = onTap
        view.onDragRect = onDragRect
        view.probe = probe
        return view
    }

    func updateUIView(_ uiView: CaptureUIView, context: Context) {
        uiView.accent = accent
        uiView.onTap = onTap
        uiView.onDragRect = onDragRect
        uiView.probe = probe
    }
}

final class CaptureUIView: UIView {
    var accent: UIColor = .systemBlue {
        didSet {
            highlightView.layer.borderColor = accent.cgColor
            highlightView.backgroundColor = accent.withAlphaComponent(0.10)
            titleContainer.backgroundColor = accent
            selectionView.layer.borderColor = accent.cgColor
            selectionView.backgroundColor = accent.withAlphaComponent(0.08)
        }
    }
    var onTap: ((CGPoint) -> Void)?
    var onDragRect: ((CGRect) -> Void)?
    var probe: ((CGPoint) -> AnnotationCapture.Probe?)?

    private let highlightView = UIView()
    private let titleLabel = UILabel()
    private let titleContainer = UIView()
    private let selectionView = UIView()
    private var lastProbePoint = CGPoint(x: -1000, y: -1000)
    private var lastProbeTime: CFTimeInterval = 0
    private var dragStart: CGPoint?
    private var isScrubbing = false
    private var lastHighlightRect = CGRect.null
    private let scrubFeedback = UISelectionFeedbackGenerator()

    /// Same threshold as Agentation's DRAG_THRESHOLD.
    private static let dragThreshold: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.04)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))

        // Hold still → marquee multi-select (haptic confirms). Move right away →
        // the long-press fails and the pan takes over as a scrub: the element
        // under the finger highlights live, release selects it.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.4
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        highlightView.isUserInteractionEnabled = false
        highlightView.layer.borderColor = accent.cgColor
        highlightView.layer.borderWidth = 2
        highlightView.layer.cornerRadius = 5
        highlightView.backgroundColor = accent.withAlphaComponent(0.10)
        highlightView.isHidden = true
        addSubview(highlightView)

        titleContainer.isUserInteractionEnabled = false
        titleContainer.backgroundColor = accent
        titleContainer.layer.cornerRadius = 4
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleContainer.addSubview(titleLabel)
        titleContainer.isHidden = true
        addSubview(titleContainer)

        selectionView.isUserInteractionEnabled = false
        selectionView.layer.borderColor = accent.cgColor
        selectionView.layer.borderWidth = 1.5
        selectionView.layer.cornerRadius = 3
        selectionView.backgroundColor = accent.withAlphaComponent(0.08)
        selectionView.isHidden = true
        addSubview(selectionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        showHighlight(at: point) // touch devices get the flash as feedback
        guard let window else { return }
        onTap?(convert(point, to: window))
    }

    /// Scrub: drag the finger and the element underneath highlights live (outline
    /// + name, the touch equivalent of the web tool's hover); releasing selects it.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            isScrubbing = true
            guard abs(point.x - lastProbePoint.x) + abs(point.y - lastProbePoint.y) > 4 else { return }
            guard CACurrentMediaTime() - lastProbeTime > 0.08 else { return }
            lastProbePoint = point
            lastProbeTime = CACurrentMediaTime()
            showHighlight(at: point)
        case .ended:
            isScrubbing = false
            guard let window else { return }
            showHighlight(at: point)
            onTap?(convert(point, to: window))
        default:
            isScrubbing = false
            highlightView.isHidden = true
            titleContainer.isHidden = true
        }
    }

    /// Marquee multi-select, behind a deliberate long-press so it can't be
    /// triggered by accident while scrubbing. A still long-press (no drag)
    /// falls back to selecting the element under the finger.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            dragStart = point
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            highlightView.isHidden = true
            titleContainer.isHidden = true
            selectionView.frame = CGRect(origin: point, size: .zero)
            selectionView.isHidden = false
        case .changed:
            guard let start = dragStart else { return }
            selectionView.frame = CGRect(origin: start, size: .zero).union(CGRect(origin: point, size: .zero))
        case .ended:
            defer { dragStart = nil; selectionView.isHidden = true }
            guard let start = dragStart, let window else { return }
            let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: point, size: .zero))
            if max(rect.width, rect.height) >= Self.dragThreshold {
                onDragRect?(convert(rect, to: window))
            } else {
                onTap?(convert(point, to: window))
            }
        default:
            dragStart = nil
            selectionView.isHidden = true
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: self)
            guard abs(point.x - lastProbePoint.x) + abs(point.y - lastProbePoint.y) > 4 else { return }
            // Each probe walks the whole accessibility tree — cap the rate too,
            // not just the distance, or fast pointer sweeps hitch.
            guard CACurrentMediaTime() - lastProbeTime > 0.08 else { return }
            lastProbePoint = point
            lastProbeTime = CACurrentMediaTime()
            showHighlight(at: point)
        default:
            highlightView.isHidden = true
            titleContainer.isHidden = true
        }
    }

    private func showHighlight(at point: CGPoint) {
        guard let window, let probe = probe?(convert(point, to: window)) else {
            highlightView.isHidden = true
            titleContainer.isHidden = true
            return
        }
        let windowRect = window.screen.coordinateSpace.convert(probe.frameInScreen, to: window.coordinateSpace)
        let local = convert(windowRect, from: window)
        // A tick each time the scrub crosses onto a different element — the finger
        // "feels" the component boundaries.
        if isScrubbing, local != lastHighlightRect, !lastHighlightRect.isNull {
            scrubFeedback.selectionChanged()
        }
        lastHighlightRect = local
        highlightView.frame = local
        highlightView.isHidden = false

        titleLabel.text = probe.title
        titleLabel.sizeToFit()
        let size = CGSize(width: titleLabel.bounds.width + 12, height: titleLabel.bounds.height + 6)
        titleLabel.frame = CGRect(x: 6, y: 3, width: titleLabel.bounds.width, height: titleLabel.bounds.height)
        var origin = CGPoint(x: local.minX, y: local.minY - size.height - 4)
        if origin.y < 2 { origin.y = local.maxY + 4 }
        origin.x = min(max(2, origin.x), max(2, bounds.width - size.width - 2))
        titleContainer.frame = CGRect(origin: origin, size: size)
        titleContainer.isHidden = false
    }
}

// MARK: - Draw mode

/// Freehand strokes over the frozen (or live) UI. Strokes accumulate; lifting the
/// finger for more than a beat, or tapping Done in the toolbar, hands them to a
/// new annotation.
private struct DrawCanvasView: UIViewRepresentable {
    var onFinish: ([[CGPoint]], CGRect) -> Void

    func makeUIView(context: Context) -> DrawUIView {
        let view = DrawUIView()
        view.onFinish = onFinish
        view.accent = AnnotationOverlayController.shared.store.settings.accent.uiColor
        return view
    }

    func updateUIView(_ uiView: DrawUIView, context: Context) {
        uiView.onFinish = onFinish
    }
}

final class DrawUIView: UIView {
    var onFinish: (([[CGPoint]], CGRect) -> Void)?
    var accent: UIColor = .systemBlue

    private var strokes: [[CGPoint]] = []
    private var current: [CGPoint] = []
    private let shape = CAShapeLayer()
    private var finishTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.03)
        shape.fillColor = nil
        shape.lineWidth = 3
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        shape.strokeColor = accent.cgColor
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            finishTimer?.invalidate()
            current = [point]
        case .changed:
            current.append(point)
            redraw()
        case .ended, .cancelled:
            if current.count > 1 { strokes.append(current) }
            current = []
            redraw()
            // A short pause after the last stroke ends the drawing — mirrors the
            // web tool, where closing draw mode attaches the strokes.
            finishTimer?.invalidate()
            finishTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish() }
            }
        default:
            break
        }
    }

    /// Leaving draw mode tears this view down (toolbar toggle, Esc, mode switch) —
    /// commit pending strokes instead of dropping them.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        finishTimer?.invalidate()
        if current.count > 1 { strokes.append(current) }
        current = []
        finish()
    }

    private func finish() {
        guard !strokes.isEmpty else { return }
        var bounds = CGRect.null
        for stroke in strokes {
            for point in stroke {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
        }
        let done = strokes
        strokes = []
        redraw()
        // Async: teardown-time commits run inside a SwiftUI update pass — don't
        // publish new state (the draft) synchronously from it.
        let callback = onFinish
        Task { @MainActor in callback?(done, bounds) }
    }

    private func redraw() {
        let path = UIBezierPath()
        for stroke in strokes + (current.count > 1 ? [current] : []) {
            guard let first = stroke.first else { continue }
            path.move(to: first)
            stroke.dropFirst().forEach { path.addLine(to: $0) }
        }
        shape.path = path.cgPath
    }
}

// MARK: - Layout mode

/// Agentation's design mode, translated to iOS: drag an element to propose a move
/// (rearrange), long-press empty space to propose a new block (placement). The app
/// itself is never mutated — only proxy rectangles over it.
private struct LayoutModeView: View {
    @ObservedObject var controller: AnnotationOverlayController

    @State private var proxyOriginal: CGRect?
    @State private var proxyCurrent: CGRect?
    @State private var proxyTitle = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.03)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(placementGesture(in: geo.size))

                if let original = proxyOriginal, let current = proxyCurrent {
                    let accent = controller.store.settings.accent.color
                    Rectangle()
                        .stroke(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: original.width, height: original.height)
                        .position(x: original.midX, y: original.midY)
                    Rectangle()
                        .fill(accent.opacity(0.12))
                        .overlay(Rectangle().stroke(accent, lineWidth: 2))
                        .frame(width: current.width, height: current.height)
                        .position(x: current.midX, y: current.midY)
                        .overlay(alignment: .top) {
                            Text(proxyTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(accent, in: RoundedRectangle(cornerRadius: 4))
                                .position(x: current.midX, y: max(10, current.minY - 14))
                        }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if proxyOriginal == nil {
                    guard let probe = controller.probe(atWindowPoint: value.startLocation),
                          let main = controller.mainWindow() else { return }
                    let windowRect = main.screen.coordinateSpace.convert(probe.frameInScreen, to: main.coordinateSpace)
                    proxyOriginal = windowRect
                    proxyTitle = probe.title
                }
                if let original = proxyOriginal {
                    proxyCurrent = original.offsetBy(dx: value.translation.width, dy: value.translation.height)
                }
            }
            .onEnded { _ in
                defer { proxyOriginal = nil; proxyCurrent = nil }
                guard let original = proxyOriginal, let current = proxyCurrent,
                      original != current else { return }
                let result = baseCapture(at: CGPoint(x: current.midX, y: current.midY))
                var annotation = result.annotation
                annotation.kind = .rearrange
                annotation.element = proxyTitle
                annotation.rearrange = AnnotationRearrange(
                    selector: annotation.elementPath,
                    label: proxyTitle,
                    tagName: annotation.viewChain.first ?? "View",
                    originalRect: Box(original),
                    currentRect: Box(current)
                )
                controller.draft = AnnotationDraft(annotation: annotation, isNew: true, screenshot: result.screenshot)
            }
    }

    /// Two-finger tap drops a placement block (the palette-less iOS stand-in for
    /// dragging a design component onto the page).
    private func placementGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .global)
            .onEnded { value in
                let result = baseCapture(at: value.location)
                var annotation = result.annotation
                annotation.kind = .placement
                annotation.element = "New component"
                annotation.placement = AnnotationPlacement(
                    componentType: "block",
                    width: 160,
                    height: 90,
                    scrollY: 0,
                    text: nil
                )
                controller.draft = AnnotationDraft(annotation: annotation, isNew: true, screenshot: result.screenshot)
            }
    }

    private func baseCapture(at windowPoint: CGPoint) -> AnnotationCapture.Result {
        guard let main = controller.mainWindow() else {
            return AnnotationCapture.Result(annotation: Annotation(), screenshot: nil)
        }
        let screenPoint = main.coordinateSpace.convert(windowPoint, to: main.screen.coordinateSpace)
        return AnnotationCapture.capture(atScreenPoint: screenPoint, in: main)
    }
}

// MARK: - Installation from SwiftUI

struct AnnotationSceneGrabber: UIViewRepresentable {
    final class GrabberView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            AnnotationOverlayController.shared.install(in: scene)
        }
    }

    func makeUIView(context: Context) -> GrabberView { GrabberView() }
    func updateUIView(_ uiView: GrabberView, context: Context) {}
}
#endif
