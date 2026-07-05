//
//  AnnotationOverlay.swift
//
//  Passthrough window above the app (the classic debug-tool pattern, à la FLEX):
//  floating pill → annotation mode → tap captured → note → prompt export. The window
//  only eats touches on the pill, in annotation mode, or while one of its sheets is
//  open; the rest of the time the app behaves as if it weren't there.
//

#if DEBUG
import Combine
import SwiftUI
import UIKit

@MainActor
final class AnnotationOverlayController: ObservableObject {
    static let shared = AnnotationOverlayController()

    @Published var isAnnotating = false
    lazy var store = AnnotationStore()

    /// Pill frame (window coordinates) — the only interactive zone when idle.
    var pillFrame: CGRect = .zero

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
    }

    /// The app window under the overlay: what we screenshot and hit-test.
    func mainWindow() -> UIWindow? {
        guard let scene = overlayWindow?.windowScene else { return nil }
        let candidates = scene.windows.filter { $0 !== overlayWindow && !$0.isHidden }
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    func captureTap(atOverlayPoint point: CGPoint) -> AnnotationCapture.Result? {
        guard let overlayWindow, let main = mainWindow() else { return nil }
        let screenPoint = overlayWindow.coordinateSpace.convert(point, to: overlayWindow.screen.coordinateSpace)
        return AnnotationCapture.capture(atScreenPoint: screenPoint, in: main)
    }

    /// Presenting our sheets makes the overlay window key; hand key status back so
    /// the app's own text fields keep their keyboard afterwards.
    func restoreMainKeyWindow() {
        mainWindow()?.makeKey()
    }
}

/// Only opaque to touches while the tool is in use.
///
/// The pass-through decision is made purely from state + the pill's UIKit frame —
/// never by comparing `super.hitTest`'s result to the root view. SwiftUI controls
/// don't create dedicated UIViews, so a click on the pill legitimately resolves to
/// the hosting view itself; an identity check would swallow it.
final class AnnotationWindow: UIWindow {
    weak var controller: AnnotationOverlayController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller else { return nil }
        let interactive = controller.isAnnotating
            || rootViewController?.presentedViewController != nil
            || controller.pillFrame.insetBy(dx: -12, dy: -12).contains(point)
        guard interactive else { return nil }
        return super.hitTest(point, with: event)
    }
}

// MARK: - Overlay root

private struct AnnotationDraft: Identifiable {
    let id = UUID()
    let result: AnnotationCapture.Result
}

struct AnnotationOverlayRoot: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore

    @State private var draft: AnnotationDraft?
    @State private var showList = false
    /// Pill centre, in the overlay's own coordinates. `nil` → default bottom-leading.
    @State private var customCenter: CGPoint?
    @State private var dragCenter: CGPoint?

    var body: some View {
        ZStack {
            if controller.isAnnotating {
                captureLayer
                annotationHint
            }
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .sheet(item: $draft) { draft in
            AnnotationNoteSheet(result: draft.result) { note in
                var annotation = draft.result.annotation
                annotation.note = note
                store.add(annotation, screenshot: draft.result.screenshot)
                self.draft = nil
            } onCancel: {
                self.draft = nil
            }
            .onDisappear { controller.restoreMainKeyWindow() }
        }
        .sheet(isPresented: $showList) {
            AnnotationListSheet(store: store)
                .onDisappear { controller.restoreMainKeyWindow() }
        }
    }

    private var captureLayer: some View {
        Color.blue.opacity(0.04)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .global) { location in
                if let result = controller.captureTap(atOverlayPoint: location) {
                    draft = AnnotationDraft(result: result)
                }
            }
            .ignoresSafeArea()
    }

    private var annotationHint: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.blue)
                Text("Tap the element to annotate")
                Button("Done") {
                    controller.isAnnotating = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.top, 64)
            Spacer()
        }
    }

    private var pill: some View {
        GeometryReader { geo in
            pillBody
                .position(clamped(dragCenter ?? customCenter ?? defaultCenter(in: geo.size), in: geo.size))
        }
    }

    private func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: 76, y: size.height - 120)
    }

    private func clamped(_ center: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(center.x, 55), max(size.width - 55, 55)),
            y: min(max(center.y, 90), max(size.height - 30, 90))
        )
    }

    private var pillBody: some View {
        HStack(spacing: 0) {
            Button {
                controller.isAnnotating.toggle()
            } label: {
                Image(systemName: controller.isAnnotating ? "xmark.circle.fill" : "scope")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(controller.isAnnotating ? .red : .blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().frame(height: 20)
            Button {
                showList = true
            } label: {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 44)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if !store.annotations.isEmpty {
                            Text("\(store.annotations.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                                .offset(x: 4, y: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        // UIKit ground truth for the window's hitTest — same coordinate space, no
        // SwiftUI global-space guesswork, and it tracks drags because .position is
        // real layout (unlike .offset, which geometry readers don't see).
        .background(PillFrameReader { frame in
            controller.pillFrame = frame
        })
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { dragCenter = $0.location }
                .onEnded { value in
                    customCenter = value.location
                    dragCenter = nil
                }
        )
    }
}

/// Reports the pill's frame in window coordinates whenever UIKit moves it.
private struct PillFrameReader: UIViewRepresentable {
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

// MARK: - Note sheet

private struct AnnotationNoteSheet: View {
    let result: AnnotationCapture.Result
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Captured element") {
                    let a = result.annotation
                    LabeledContent("Type", value: a.elementType)
                    if let label = a.elementLabel, !label.isEmpty {
                        LabeledContent("Label", value: label)
                    }
                    LabeledContent("Screen", value: a.screenHint)
                    if !a.nearbyTexts.isEmpty {
                        LabeledContent("Nearby", value: a.nearbyTexts.prefix(3).joined(separator: " · "))
                    }
                }
                Section("Your note") {
                    TextField(
                        "What's wrong? What should change?",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .focused($noteFocused)
                }
            }
            .navigationTitle("Annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(note) }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { noteFocused = true }
    }
}

// MARK: - List + export

private struct AnnotationListSheet: View {
    @ObservedObject var store: AnnotationStore
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if store.annotations.isEmpty {
                    ContentUnavailableView(
                        "No annotations yet",
                        systemImage: "scope",
                        description: Text("Enable annotation mode with the pill, then tap any element of the interface.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.annotations) { annotation in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(annotation.note.isEmpty ? "(no note)" : annotation.note)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text("\(annotation.elementType)\(annotation.elementLabel.map { " “\($0)”" } ?? "") — \(annotation.screenHint)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .onDelete { store.remove(at: $0) }
                        } footer: {
                            Text("“Copy prompt” puts the markdown on the pasteboard (Universal Clipboard forwards it to your Mac). Files: \(store.directory.path)")
                        }
                    }
                }
            }
            .navigationTitle("Annotations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = store.markdownPrompt()
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(store.annotations.isEmpty)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.annotations.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete all annotations?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) { store.clear() }
            }
        }
        .presentationDetents([.medium, .large])
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
