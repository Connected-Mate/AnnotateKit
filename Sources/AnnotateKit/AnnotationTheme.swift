//
//  AnnotationTheme.swift
//
//  Design tokens mirroring Agentation's toolbar/popup design language (dark
//  #1a1a1a surfaces, 7-accent palette in sRGB + Display P3, spring-ish cubic
//  béziers). Values re-typed from the published stylesheet — no Agentation
//  assets are embedded. Agentation's font stack is `system-ui`, which on Apple
//  platforms is the system font — so the typography matches by construction.
//

#if DEBUG
import SwiftUI
import UIKit

enum AnnotationTheme {

    // MARK: Accents (sRGB fallback + Display P3, like Agentation's @supports pair)

    enum Accent: String, Codable, CaseIterable, Identifiable {
        case indigo, blue, cyan, green, yellow, orange, red

        var id: String { rawValue }

        /// Single source of truth for the Display P3 components; `color` and
        /// `uiColor` are derived views of the same triplet.
        private var p3: (red: Double, green: Double, blue: Double) {
            switch self {
            case .indigo: (0.38, 0.33, 0.96)
            case .blue:   (0.00, 0.53, 1.00)
            case .cyan:   (0.00, 0.76, 0.82)
            case .green:  (0.20, 0.78, 0.35)
            case .yellow: (1.00, 0.80, 0.00)
            case .orange: (1.00, 0.55, 0.16)
            case .red:    (1.00, 0.22, 0.24)
            }
        }

        var color: Color { Color(.displayP3, red: p3.red, green: p3.green, blue: p3.blue) }
        var uiColor: UIColor { UIColor(displayP3Red: p3.red, green: p3.green, blue: p3.blue, alpha: 1) }
    }

    // MARK: Surfaces

    /// Toolbar / popup background — #1a1a1a in dark theme, white in light.
    static func surface(_ theme: ThemeMode) -> Color {
        theme == .dark ? Color(white: 0x1a / 255.0) : .white
    }

    static func onSurface(_ theme: ThemeMode) -> Color {
        theme == .dark ? .white : Color(white: 0.1)
    }

    /// Secondary label — rgba(255,255,255,.5) on dark.
    static func onSurfaceSecondary(_ theme: ThemeMode) -> Color {
        theme == .dark ? .white.opacity(0.5) : .black.opacity(0.5)
    }

    /// Inset field background — rgba(255,255,255,.05) on dark.
    static func field(_ theme: ThemeMode) -> Color {
        theme == .dark ? .white.opacity(0.05) : .black.opacity(0.05)
    }

    static func fieldBorder(_ theme: ThemeMode) -> Color {
        theme == .dark ? .white.opacity(0.15) : .black.opacity(0.15)
    }

    enum ThemeMode: String, Codable { case dark, light }

    // MARK: Metrics

    /// Toolbar: 44 pt collapsed circle ↔ 44 pt-tall pill, radius 22/24, padding 6.
    static let toolbarHeight: CGFloat = 44
    static let toolbarCollapsedRadius: CGFloat = 22
    static let toolbarExpandedRadius: CGFloat = 24
    static let toolbarPadding: CGFloat = 6

    /// Numbered annotation marker: 22 pt circle (26 pt rounded-square when multi-select).
    static let markerSize: CGFloat = 22
    static let multiSelectMarkerSize: CGFloat = 26
    static let multiSelectMarkerRadius: CGFloat = 6

    /// Note popup: 280 pt wide, radius 16.
    static let popupWidth: CGFloat = 280
    static let popupRadius: CGFloat = 16

    static let badgeSize: CGFloat = 18

    // MARK: Motion (Agentation's cubic-béziers, verbatim)

    /// Toolbar expand/collapse — cubic-bezier(0.19, 1, 0.22, 1), 0.4 s.
    static let toolbarCurve = Animation.timingCurve(0.19, 1, 0.22, 1, duration: 0.4)
    /// Entrance — cubic-bezier(0.34, 1.2, 0.64, 1), 0.5 s.
    static let entranceCurve = Animation.timingCurve(0.34, 1.2, 0.64, 1, duration: 0.5)
    /// Popup enter — cubic-bezier(0.34, 1.56, 0.64, 1), 0.2 s (overshoot).
    static let popupCurve = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.2)
    /// Marker in — cubic-bezier(0.22, 1, 0.36, 1), 0.25 s.
    static let markerCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)
}
#endif
