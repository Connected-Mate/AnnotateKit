//
//  AnnotationToolbar.swift
//
//  The floating toolbar, styled after Agentation's: a 44 pt dark circle that
//  expands into a pill of icon actions, draggable, with a count badge, a live
//  connection dot when syncing, and a one-time entrance animation.
//

#if DEBUG
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Entrance plays once per process, like the web tool's once-per-page-load flag.
@MainActor private var hasPlayedEntranceAnimation = false

#if canImport(UIKit)
private typealias HapticStyle = UIImpactFeedbackGenerator.FeedbackStyle
#else
private enum HapticStyle { case light, medium }
#endif

struct AnnotationToolbar: View {
    @ObservedObject var controller: AnnotationOverlayController
    @ObservedObject var store: AnnotationStore
    @ObservedObject private var sync = AnnotationSync.shared

    @State private var customCenter: CGPoint? = Self.loadPosition()
    @State private var dragCenter: CGPoint?
    @State private var isPickedUp = false
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
        // Agentation sits bottom-right, 20 pt in — lifted above any bottom bar.
        CGPoint(x: size.width - 42, y: size.height - 62 - bottomBarInset())
    }

    private func clamped(_ center: CGPoint, in size: CGSize) -> CGPoint {
        // Half the measured toolbar size, so the expanded pill never leaves the screen.
        let halfWidth = max(measuredSize.width / 2, 22) + 8
        let halfHeight = max(measuredSize.height / 2, 22) + 8
        // Never over the app's tab bar: the window's hitTest gives the toolbar
        // priority around its frame, so a toolbar parked on the tab bar makes
        // the tabs under it untappable (and its ±12 pt grace zone eats taps
        // next to it too). Applies to saved positions as well — a position
        // stored before this rule existed gets lifted out of the strip.
        let bottomLimit = size.height - halfHeight - bottomBarInset()
        return CGPoint(
            x: min(max(center.x, halfWidth), max(size.width - halfWidth, halfWidth)),
            y: min(max(center.y, halfHeight + 40), max(bottomLimit, halfHeight + 40))
        )
    }

    /// Height of the strip covered by a bottom-pinned UITabBar in the app
    /// window (0 when the app has none). SwiftUI's TabView is UITabBar-backed.
    private func bottomBarInset() -> CGFloat {
        #if canImport(UIKit)
        guard let main = controller.mainWindow(),
              let tabBar = Self.firstTabBar(in: main),
              !tabBar.isHidden, tabBar.alpha > 0.01 else { return 0 }
        let frame = tabBar.convert(tabBar.bounds, to: main)
        guard frame.maxY > main.bounds.maxY - 1 else { return 0 } // bottom-pinned only
        return max(0, main.bounds.maxY - frame.minY)
        #else
        return 0
        #endif
    }

    #if canImport(UIKit)
    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let bar = firstTabBar(in: subview) { return bar }
        }
        return nil
    }
    #endif

    private var toolbarBody: some View {
        Group {
            if controller.isAnnotating {
                expanded
            } else {
                collapsed
            }
        }
        .scaleEffect(isPickedUp ? 1.12 : (entered ? 1 : 0.6))
        .opacity(entered ? 1 : 0)
        .shadow(color: .black.opacity(isPickedUp ? 0.3 : 0), radius: isPickedUp ? 22 : 0, y: 8)
        // SwiftUI-side frame reporting, NOT the UIKit FrameReporter: during the
        // expand→collapse transition the reporter view's UIKit frame can freeze
        // mid-animation and never get a final layout pass — the window then
        // hit-tests against a ghost frame ~100 pt away from the visible circle,
        // and the toolbar becomes untappable until something forces a layout.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { reportFrame(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in reportFrame(frame) }
        })
        // `.highPriorityGesture`, so a deliberate drag (≥14 pt) wins over the
        // collapsed circle's tap and the expanded pill's buttons — while a plain
        // tap (which never travels 14 pt) falls through to them untouched.
        .highPriorityGesture(moveGesture)
        .animation(AnnotationTheme.toolbarCurve, value: controller.isAnnotating)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isPickedUp)
    }

    /// Drag the toolbar to reposition it. A plain `DragGesture` with a raised
    /// activation threshold (14 pt) is the reliable primitive here:
    ///
    /// - A **quick tap** never travels 14 pt, so it always reaches the Button —
    ///   annotation mode toggles reliably. (The earlier long-press approach
    ///   started on touch-*down* and stole the tap, so tapping the circle stopped
    ///   activating annotation at all.)
    /// - A **deliberate drag** (finger travels ≥14 pt) picks the toolbar up —
    ///   haptic + it grows — and you slide it anywhere, e.g. out of a dead zone.
    ///
    /// Tapping *elements* on the canvas is a separate view and is untouched.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { value in
                if !isPickedUp {
                    isPickedUp = true
                    Self.haptic(.medium)   // "you've grabbed it"
                }
                dragCenter = value.location
            }
            .onEnded { value in
                customCenter = value.location
                Self.savePosition(value.location)
                Self.haptic(.light)        // "dropped"
                dragCenter = nil
                isPickedUp = false
            }
    }

    private func reportFrame(_ frame: CGRect) {
        controller.toolbarFrame = frame
        if abs(frame.width - measuredSize.width) > 0.5 || abs(frame.height - measuredSize.height) > 0.5 {
            measuredSize = frame.size
        }
    }

    @MainActor
    private static func haptic(_ style: HapticStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    // MARK: Collapsed — 44 pt circle

    private var collapsed: some View {
        // A plain tappable view — deliberately NOT a Button. A child Button's own
        // gesture recognizer fought the toolbar's drag gesture (it alternately
        // swallowed the tap or blocked the drag). With a plain view, `onTapGesture`
        // (toggle) and the parent's `highPriorityGesture` drag compose cleanly.
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
            .onTapGesture { controller.toggleActive() }
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
