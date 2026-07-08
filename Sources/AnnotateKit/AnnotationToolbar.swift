//
//  AnnotationToolbar.swift
//
//  The floating toolbar, styled after Agentation's: a 44 pt dark circle that
//  expands into a pill of icon actions, draggable, with a count badge, a live
//  connection dot when syncing, and a one-time entrance animation.
//

#if DEBUG
import SwiftUI

/// Entrance plays once per process, like the web tool's once-per-page-load flag.
@MainActor private var hasPlayedEntranceAnimation = false

struct AnnotationToolbar: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore
    @ObservedObject private var sync = AnnotationSync.shared

    @State private var customCenter: CGPoint? = Self.loadPosition()
    @State private var dragCenter: CGPoint?
    @State private var entered = hasPlayedEntranceAnimation
    @State private var measuredSize: CGSize = .zero

    private static let positionKey = "feedback-toolbar-position"

    private var theme: AnnotationTheme.ThemeMode { store.settings.theme }
    private var accent: Color { store.settings.accent.color }

    var body: some View {
        GeometryReader { geo in
            toolbarBody
                .position(clamped(dragCenter ?? customCenter ?? defaultCenter(in: geo.size), in: geo.size))
        }
        .onAppear {
            guard !hasPlayedEntranceAnimation else { return }
            hasPlayedEntranceAnimation = true
            withAnimation(AnnotationTheme.entranceCurve.delay(0.15)) { entered = true }
        }
    }

    private func defaultCenter(in size: CGSize) -> CGPoint {
        // Agentation sits bottom-right, 20 pt in.
        CGPoint(x: size.width - 42, y: size.height - 62)
    }

    private func clamped(_ center: CGPoint, in size: CGSize) -> CGPoint {
        // Half the measured toolbar size, so the expanded pill never leaves the screen.
        let halfWidth = max(measuredSize.width / 2, 22) + 8
        let halfHeight = max(measuredSize.height / 2, 22) + 8
        return CGPoint(
            x: min(max(center.x, halfWidth), max(size.width - halfWidth, halfWidth)),
            y: min(max(center.y, halfHeight + 40), max(size.height - halfHeight, halfHeight + 40))
        )
    }

    private var toolbarBody: some View {
        Group {
            if controller.isAnnotating {
                expanded
            } else {
                collapsed
            }
        }
        .scaleEffect(entered ? 1 : 0.6)
        .opacity(entered ? 1 : 0)
        .background(FrameReporter { frame in
            controller.toolbarFrame = frame
            if abs(frame.width - measuredSize.width) > 0.5 || abs(frame.height - measuredSize.height) > 0.5 {
                Task { @MainActor in measuredSize = frame.size }
            }
        })
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { dragCenter = $0.location }
                .onEnded { value in
                    customCenter = value.location
                    dragCenter = nil
                    Self.savePosition(value.location)
                }
        )
        .animation(AnnotationTheme.toolbarCurve, value: controller.isAnnotating)
    }

    // MARK: Collapsed — 44 pt circle

    private var collapsed: some View {
        Button {
            controller.toggleActive()
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AnnotationTheme.onSurface(theme))
                .frame(width: AnnotationTheme.toolbarHeight, height: AnnotationTheme.toolbarHeight)
                .background(
                    AnnotationTheme.surface(theme),
                    in: RoundedRectangle(cornerRadius: AnnotationTheme.toolbarCollapsedRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AnnotationTheme.toolbarCollapsedRadius)
                        .stroke(.white.opacity(theme == .dark ? 0.08 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var badge: some View {
        if !store.annotations.isEmpty {
            Text("\(store.annotations.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: AnnotationTheme.badgeSize, minHeight: AnnotationTheme.badgeSize)
                .background(accent, in: Capsule())
                .offset(x: 5, y: -3)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: Expanded — pill of actions

    private var expanded: some View {
        HStack(spacing: 2) {
            connectionDot
            toolButton(
                icon: controller.isFrozen ? "play.fill" : "pause.fill",
                active: controller.isFrozen,
                hint: "Freeze animations (P)"
            ) { controller.toggleFreeze() }
            toolButton(
                icon: "rectangle.3.group",
                active: controller.isLayoutMode,
                hint: "Layout mode (L)"
            ) { controller.isLayoutMode.toggle(); if controller.isLayoutMode { controller.isDrawMode = false } }
            toolButton(
                icon: "scribble.variable",
                active: controller.isDrawMode,
                hint: "Draw"
            ) { controller.isDrawMode.toggle(); if controller.isDrawMode { controller.isLayoutMode = false } }
            toolButton(
                icon: controller.markersVisible ? "eye" : "eye.slash",
                active: false,
                hint: "Toggle markers (H)"
            ) { controller.markersVisible.toggle() }
            toolButton(
                icon: "list.clipboard",
                active: false,
                hint: "Annotations",
                badgeCount: store.annotations.count
            ) { controller.showList = true }
            toolButton(
                icon: controller.copied ? "checkmark" : "doc.on.doc",
                active: controller.copied,
                hint: "Copy output (C)",
                disabled: store.annotations.isEmpty
            ) { controller.copyOutput() }
            if controller.hasSendTarget {
                sendButton
            }
            toolButton(icon: "gearshape", active: controller.showSettings, hint: "Settings") {
                controller.showSettings.toggle()
            }
            toolButton(icon: "xmark", active: false, hint: "Close (Esc)") {
                controller.isAnnotating = false
            }
        }
        .padding(AnnotationTheme.toolbarPadding)
        .background(
            AnnotationTheme.surface(theme),
            in: RoundedRectangle(cornerRadius: AnnotationTheme.toolbarExpandedRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AnnotationTheme.toolbarExpandedRadius)
                .stroke(.white.opacity(theme == .dark ? 0.08 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    @ViewBuilder
    private var connectionDot: some View {
        if sync.state != .disabled {
            Circle()
                .fill(sync.state == .connected ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
                .modifier(PulseEffect(period: sync.state == .connected ? 2.5 : 1.0))
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .accessibilityLabel(sync.state == .connected ? "Server connected" : "Connecting")
        }
    }

    private var sendButton: some View {
        Button {
            controller.send()
        } label: {
            Group {
                switch controller.sendState {
                case .idle:
                    Image(systemName: "paperplane")
                case .sending:
                    ProgressView().controlSize(.small).tint(AnnotationTheme.onSurface(theme))
                case .sent:
                    Image(systemName: "checkmark").foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(controller.sendState == .idle ? AnnotationTheme.onSurface(theme) : .clear)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.annotations.isEmpty || controller.sendState != .idle)
        .opacity(store.annotations.isEmpty ? 0.35 : 1)
        .accessibilityLabel("Send (S)")
    }

    private func toolButton(
        icon: String,
        active: Bool,
        hint: String,
        badgeCount: Int = 0,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? accent : AnnotationTheme.onSurface(theme))
                .frame(width: 32, height: 32)
                .background(
                    active ? accent.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(accent, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(hint)
    }

    // MARK: Position persistence (same key as the web tool)

    private static func loadPosition() -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: positionKey) as? [Double],
              values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private static func savePosition(_ point: CGPoint) {
        UserDefaults.standard.set([Double(point.x), Double(point.y)], forKey: positionKey)
    }
}

/// Slow opacity pulse for the connection dot.
private struct PulseEffect: ViewModifier {
    let period: Double
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.35 : 1)
            .animation(.easeInOut(duration: period).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

#endif
