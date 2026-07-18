//
//  AnnotationPanels.swift
//
//  The Agentation-style surfaces: the dark 280 pt note popup anchored near the
//  annotated element, the settings card, and the annotation list sheet.
//

#if DEBUG
import Combine
import SwiftUI
import UIKit

// MARK: - Note popup

struct AnnotationPopupHost: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore
    let draft: AnnotationDraft

    @StateObject private var keyboard = KeyboardObserver()
    @State private var popupHeight: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmer — tapping outside cancels, like clicking off the web popup.
                Color.black.opacity(0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.draft = nil }

                // Live outline of the current target — as the level stepper climbs
                // the chain, the user sees exactly which block is selected. Also
                // shown when editing (best effort: the frame captured at creation)
                // and for multi-select, where every chosen element gets its box —
                // without it the popup says "N elements" and nothing tells the
                // user which ones.
                if draft.annotation.isMultiSelect == true,
                   let boxes = draft.annotation.elementBoundingBoxes {
                    MultiSelectionOverlay(rects: boxes.map(\.rect), accent: store.settings.accent.color)
                } else if let box = draft.annotation.boundingBox {
                    SelectionBoxOverlay(rect: box.rect, accent: store.settings.accent.color)
                }

                AnnotationPopup(
                    draft: draft,
                    settings: store.settings,
                    onSubmit: { annotation in
                        controller.saveDraft(annotation, isNew: draft.isNew)
                    },
                    onCancel: { controller.draft = nil },
                    onDelete: draft.isNew ? nil : {
                        store.remove(draft.annotation)
                        controller.draft = nil
                    },
                    onLevelChange: { controller.setDraftLevel($0) }
                )
                // Measure the real height — content varies (quote, pickers,
                // placement field), a fixed estimate misplaces the popup.
                .background(GeometryReader { popupGeo in
                    Color.clear
                        .onAppear { popupHeight = popupGeo.size.height }
                        .onChange(of: popupGeo.size.height) { _, height in popupHeight = height }
                })
                .position(popupPosition(in: geo.size))
            }
        }
        .ignoresSafeArea()
    }

    private func popupPosition(in size: CGSize) -> CGPoint {
        let width = AnnotationTheme.popupWidth
        let anchor = CGPoint(x: draft.annotation.x / 100 * size.width, y: draft.annotation.y)
        var x = min(max(anchor.x, width / 2 + 12), size.width - width / 2 - 12)
        var y = anchor.y + 24 + popupHeight / 2
        let bottomLimit = size.height - keyboard.height - popupHeight / 2 - 16
        if y > bottomLimit { y = anchor.y - 24 - popupHeight / 2 } // flip above
        let topLimit = popupHeight / 2 + 70 // clear of the status bar / Dynamic Island
        y = min(max(y, topLimit), max(bottomLimit, topLimit))
        if x.isNaN || y.isNaN { x = size.width / 2; y = size.height / 3 }
        return CGPoint(x: x, y: y)
    }
}

/// SwiftUI twin of `SelectionBoxView`: sharp rectangle + corner handles.
struct SelectionBoxOverlay: View {
    let rect: CGRect
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(
                        x: index % 2 == 0 ? rect.minX : rect.maxX,
                        y: index < 2 ? rect.minY : rect.maxY
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// One thin box per selected element of a multi-select — the "which ones"
/// answer the single-target corner-handle box gives for a plain tap.
struct MultiSelectionOverlay: View {
    let rects: [CGRect]
    let accent: Color

    var body: some View {
        ZStack {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct AnnotationPopup: View {
    let draft: AnnotationDraft
    let settings: AnnotationSettings
    let onSubmit: (Annotation) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onLevelChange: (Int) -> Void

    @State private var comment: String
    @State private var intent: AnnotationIntent?
    @State private var severity: AnnotationSeverity?
    @State private var componentText: String
    @State private var appeared = false
    @State private var voiceBaseline: String = ""
    @FocusState private var commentFocused: Bool
    @StateObject private var voice = AnnotationVoice()

    init(
        draft: AnnotationDraft,
        settings: AnnotationSettings,
        onSubmit: @escaping (Annotation) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)?,
        onLevelChange: @escaping (Int) -> Void = { _ in }
    ) {
        self.draft = draft
        self.settings = settings
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onLevelChange = onLevelChange
        // Dictation language: explicit setting, or the device's language/region.
        _voice = StateObject(wrappedValue: AnnotationVoice(locale: settings.resolvedVoiceLocale))
        _comment = State(initialValue: draft.annotation.comment)
        _intent = State(initialValue: draft.annotation.intent)
        _severity = State(initialValue: draft.annotation.severity)
        _componentText = State(initialValue: draft.annotation.placement?.text ?? "")
    }

    private var theme: AnnotationTheme.ThemeMode { settings.theme }
    private var accent: Color { settings.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Multi-select included: its selectedText is the joined labels of
            // the chosen elements — it names what "N elements" refers to.
            if let selected = draft.annotation.selectedText {
                Text("“\(selected)”")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                    .lineLimit(draft.annotation.isMultiSelect == true ? 3 : 2)
            }
            if draft.annotation.kind == .rearrange, let move = draft.annotation.rearrange {
                Text(rearrangeSummary(move))
                    .font(.system(size: 11))
                    .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
            }
            if draft.annotation.kind == .placement {
                TextField("Component label", text: $componentText)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(AnnotationTheme.field(theme), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(AnnotationTheme.onSurface(theme))
            }

            noteArea

            if draft.annotation.kind == .feedback {
                pickers
            }

            buttons
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .frame(width: AnnotationTheme.popupWidth)
        .background(AnnotationTheme.surface(theme), in: RoundedRectangle(cornerRadius: AnnotationTheme.popupRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AnnotationTheme.popupRadius)
                .stroke(.white.opacity(theme == .dark ? 0.08 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(AnnotationTheme.popupCurve) { appeared = true }
            // Voice-only never opens the keyboard.
            commentFocused = settings.noteInput != .voice
            // Voice-only: start listening immediately — one tap on the element,
            // then talk, like a walkie-talkie.
            if settings.noteInput == .voice { Task { await voice.start() } }
        }
        .onDisappear { voice.stop() }
        .onChange(of: voice.transcript) { _, transcript in
            guard voice.state == .listening else { return }
            comment = voiceBaseline.isEmpty
                ? transcript
                : voiceBaseline + " " + transcript
        }
        .onChange(of: voice.state) { _, state in
            if state == .listening { voiceBaseline = comment }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.annotation.element)
                    .font(.system(size: 12))
                    .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                    .lineLimit(1)
                if !draft.annotation.screenHint.isEmpty {
                    Text(draft.annotation.screenHint)
                        .font(.system(size: 10))
                        .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme).opacity(0.7))
                        .lineLimit(1)
                }
            }
            if draft.isNew, draft.hierarchy.count > 1, draft.annotation.isMultiSelect != true {
                Spacer(minLength: 0)
                levelStepper
            }
        }
    }

    /// Climb the containment chain: ▲ selects the containing block (the card,
    /// the section), ▼ goes back toward the leaf that was tapped.
    private var levelStepper: some View {
        HStack(spacing: 2) {
            levelButton(systemName: "chevron.up", enabled: draft.level < draft.hierarchy.count - 1) {
                onLevelChange(draft.level + 1)
            }
            .accessibilityLabel("Select containing element")
            levelButton(systemName: "chevron.down", enabled: draft.level > 0) {
                onLevelChange(draft.level - 1)
            }
            .accessibilityLabel("Select inner element")
        }
    }

    private func levelButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? AnnotationTheme.onSurface(theme) : AnnotationTheme.onSurfaceSecondary(theme).opacity(0.4))
                .frame(width: 24, height: 22)
                .background(AnnotationTheme.field(theme), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var noteArea: some View {
        switch settings.noteInput {
        case .keyboard:
            commentEditor
        case .voice:
            // Same popup as always — the field just fills from dictation. It
            // doesn't accept touches, so the keyboard can never come up.
            VStack(spacing: 8) {
                commentEditor.allowsHitTesting(false)
                micRow
            }
        case .both:
            VStack(spacing: 8) {
                commentEditor
                if voice.isAvailable { micRow }
            }
        }
    }

    private var micRow: some View {
        HStack(spacing: 8) {
            Button(action: voice.toggle) {
                Image(systemName: voice.state == .listening ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(voice.state == .listening ? AnnotationTheme.Accent.red.color : accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        (voice.state == .listening ? AnnotationTheme.Accent.red.color : accent).opacity(0.15),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.state == .listening ? "Stop dictation" : "Dictate")

            Text(micStatusText)
                .font(.system(size: 11))
                .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                .lineLimit(1)
            Spacer()
        }
    }

    private var micStatusText: String {
        switch voice.state {
        case .listening: return "Listening…"
        case .requesting: return "Starting…"
        case .denied: return "Permission denied"
        case .unavailable: return "Dictation unavailable"
        case .failed(let reason): return reason
        case .idle: return "Dictate"
        }
    }

    private var commentEditor: some View {
        TextEditor(text: $comment)
            .font(.system(size: 13))
            .foregroundStyle(AnnotationTheme.onSurface(theme))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 58, maxHeight: 110)
            .padding(6)
            .background(AnnotationTheme.field(theme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(commentFocused ? accent : AnnotationTheme.fieldBorder(theme), lineWidth: 1)
            )
            .focused($commentFocused)
            .overlay(alignment: .topLeading) {
                if comment.isEmpty {
                    Text("What's wrong? What should change?")
                        .font(.system(size: 13))
                        .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme).opacity(0.6))
                        .padding(EdgeInsets(top: 12, leading: 10, bottom: 0, trailing: 0))
                        .allowsHitTesting(false)
                }
            }
    }

    private var pickers: some View {
        HStack(spacing: 8) {
            chipMenu(
                label: intent?.rawValue ?? "intent",
                isSet: intent != nil
            ) {
                ForEach(AnnotationIntent.allCases, id: \.self) { value in
                    Button(value.rawValue) { intent = value }
                }
                Button("none") { intent = nil }
            }
            chipMenu(
                label: severity?.rawValue ?? "severity",
                isSet: severity != nil
            ) {
                ForEach(AnnotationSeverity.allCases, id: \.self) { value in
                    Button(value.rawValue) { severity = value }
                }
                Button("none") { severity = nil }
            }
            Spacer()
        }
    }

    private func chipMenu(label: String, isSet: Bool, @ViewBuilder content: () -> some View) -> some View {
        Menu(content: content) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSet ? accent : AnnotationTheme.onSurfaceSecondary(theme))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isSet ? accent.opacity(0.15) : AnnotationTheme.field(theme),
                    in: Capsule()
                )
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AnnotationTheme.Accent.red.color)
                        .frame(width: 28, height: 28)
                        .background(AnnotationTheme.field(theme), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AnnotationTheme.onSurface(theme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(AnnotationTheme.field(theme), in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: submit) {
                Text(draft.isNew ? "Submit" : "Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.4)
        }
    }

    private var canSubmit: Bool {
        draft.annotation.kind != .feedback
            || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        var annotation = draft.annotation
        annotation.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.intent = intent
        annotation.severity = severity
        if annotation.kind == .placement {
            annotation.placement?.text = componentText.nilIfEmpty
        }
        if !draft.isNew {
            annotation.updatedAt = ISO8601DateFormatter().string(from: .now)
        }
        onSubmit(annotation)
    }

    private func rearrangeSummary(_ move: AnnotationRearrange) -> String {
        let dx = Int(move.currentRect.x - move.originalRect.x)
        let dy = Int(move.currentRect.y - move.originalRect.y)
        return "Move \(dx >= 0 ? "+" : "")\(dx), \(dy >= 0 ? "+" : "")\(dy) pt"
    }
}

/// Keyboard height, so the popup can dodge it.
@MainActor
private final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
            Task { @MainActor [weak self] in self?.height = frame.height }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.height = 0 }
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

// MARK: - Settings card

struct AnnotationSettingsHost: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .contentShape(Rectangle())
                .onTapGesture { controller.showSettings = false }
                .ignoresSafeArea()
            AnnotationSettingsCard(controller: controller, store: store)
        }
    }
}

private struct AnnotationSettingsCard: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore

    @State private var endpoint: String = ""
    @State private var webhook: String = ""
    @State private var appeared = false

    private var theme: AnnotationTheme.ThemeMode { store.settings.theme }
    private var accent: Color { store.settings.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AnnotationTheme.onSurface(theme))
                Spacer()
                Button {
                    controller.showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                        .frame(width: 24, height: 24)
                        .background(AnnotationTheme.field(theme), in: Circle())
                }
                .buttonStyle(.plain)
            }

            row("Accent") {
                HStack(spacing: 6) {
                    ForEach(AnnotationTheme.Accent.allCases) { candidate in
                        Button {
                            store.settings.accent = candidate
                        } label: {
                            Circle()
                                .fill(candidate.color)
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if candidate == store.settings.accent {
                                        Circle().stroke(.white, lineWidth: 2).padding(2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            row("Theme") {
                segmented(
                    options: [AnnotationTheme.ThemeMode.dark, .light],
                    selected: store.settings.theme,
                    title: { $0.rawValue }
                ) { store.settings.theme = $0 }
            }

            row("Marker tap") {
                segmented(
                    options: AnnotationSettings.MarkerClickBehavior.allCases,
                    selected: store.settings.markerClickBehavior,
                    title: { $0.rawValue }
                ) { store.settings.markerClickBehavior = $0 }
            }

            row("Output detail") {
                segmented(
                    options: OutputDetailLevel.allCases,
                    selected: store.settings.detailLevel,
                    title: { $0.rawValue }
                ) { store.settings.detailLevel = $0 }
            }

            row("Note input") {
                segmented(
                    options: AnnotationSettings.NoteInput.allCases,
                    selected: store.settings.noteInput,
                    title: { $0.rawValue }
                ) { store.settings.noteInput = $0 }
            }

            if store.settings.noteInput != .keyboard {
                row("Dictation language") {
                    Menu {
                        Picker("Dictation language", selection: Binding(
                            get: { store.settings.voiceLocale ?? "" },
                            set: { store.settings.voiceLocale = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Automatic — \(AnnotationVoice.displayName(forLocaleIdentifier: Locale.autoupdatingCurrent.identifier))")
                                .tag("")
                            ForEach(AnnotationVoice.supportedLocaleIdentifiers, id: \.self) { id in
                                Text(AnnotationVoice.displayName(forLocaleIdentifier: id)).tag(id)
                            }
                        }
                    } label: {
                        HStack {
                            Text(currentVoiceLocaleName)
                                .font(.system(size: 12))
                                .foregroundStyle(AnnotationTheme.onSurface(theme))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                        }
                        .padding(8)
                        .background(AnnotationTheme.field(theme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AnnotationTheme.fieldBorder(theme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            row("Server (agentation-mcp)") {
                urlField("http://your-mac.local:4747", text: $endpoint, onCommit: commitFields)
            }

            row("Webhook") {
                urlField("https://example.com/hook", text: $webhook, onCommit: commitFields)
            }

            Button {
                controller.hideTemporarily()
            } label: {
                Text("Hide toolbar until next launch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(AnnotationTheme.field(theme), in: Capsule())
            }
            .buttonStyle(.plain)

            Text("Files: \(store.directory.path)")
                .font(.system(size: 9))
                .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme).opacity(0.7))
                .lineLimit(2)

            // Provenance — always visible where the tool is configured.
            Link(destination: URL(string: "https://www.agentation.com")!) {
                Text("Based on Agentation, the open-source web tool ↗ — it was brilliant in the browser and iOS had nothing, so we built the port. Not affiliated.")
                    .font(.system(size: 9))
                    .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme).opacity(0.7))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(AnnotationTheme.surface(theme), in: RoundedRectangle(cornerRadius: AnnotationTheme.popupRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AnnotationTheme.popupRadius)
                .stroke(.white.opacity(theme == .dark ? 0.08 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            endpoint = store.settings.endpoint
            webhook = store.settings.webhookURL
            withAnimation(AnnotationTheme.popupCurve) { appeared = true }
        }
        // Closing the card any way (X, dimmer tap) commits typed URLs — the
        // return key must not be the only path that saves them.
        .onDisappear(perform: commitFields)
    }

    private var currentVoiceLocaleName: String {
        if let id = store.settings.voiceLocale, !id.isEmpty {
            return AnnotationVoice.displayName(forLocaleIdentifier: id)
        }
        return "Automatic — \(AnnotationVoice.displayName(forLocaleIdentifier: Locale.autoupdatingCurrent.identifier))"
    }

    private func commitFields() {
        let newEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        let newWebhook = webhook.trimmingCharacters(in: .whitespaces)
        if store.settings.webhookURL != newWebhook {
            store.settings.webhookURL = newWebhook
        }
        if store.settings.endpoint != newEndpoint {
            store.settings.endpoint = newEndpoint
            AnnotationSync.shared.start(store: store)
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(AnnotationTheme.onSurfaceSecondary(theme))
            content()
        }
    }

    private func segmented<Option: Hashable>(
        options: [Option],
        selected: Option,
        title: @escaping (Option) -> String,
        select: @escaping (Option) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: option == selected ? .semibold : .regular))
                        .foregroundStyle(option == selected ? .white : AnnotationTheme.onSurfaceSecondary(theme))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            option == selected ? accent : AnnotationTheme.field(theme),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func urlField(_ placeholder: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 12, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .foregroundStyle(AnnotationTheme.onSurface(theme))
            .padding(8)
            .background(AnnotationTheme.field(theme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AnnotationTheme.fieldBorder(theme), lineWidth: 1))
            .onSubmit(onCommit)
    }
}

// MARK: - List + export sheet

struct AnnotationListSheet: View {
    @ObservedObject var controller: AnnotationOverlayController
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
                        description: Text("Open the toolbar, then tap any element of the interface.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(Array(store.annotations.enumerated()), id: \.element.id) { index, annotation in
                                row(number: index + 1, annotation: annotation)
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
                        controller.copyOutput()
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
                Button("Delete all", role: .destructive) { controller.clearAll() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(number: Int, annotation: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(store.settings.accent.color, in: Circle())
                Text(annotation.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Text("\(annotation.element) — \(annotation.screenHint)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let intent = annotation.intent { tag(intent.rawValue) }
                if let severity = annotation.severity { tag(severity.rawValue) }
                if annotation.status != .pending { tag(annotation.status.rawValue) }
                if let thread = annotation.thread, !thread.isEmpty { tag("\(thread.count) replies") }
                if annotation._syncedTo != nil { tag("synced") }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
            controller.draft = AnnotationDraft(annotation: annotation, isNew: false)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
#endif
