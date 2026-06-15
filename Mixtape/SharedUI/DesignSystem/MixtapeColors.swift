// MixtapeColors.swift
// Mixtape — Design System
//
// Original visual identity: deep indigo base, warm amber accent.
// Intentionally distinct from any streaming-platform palette.
//
// Usage: Color.mixPrimary, Color.mixBackground, etc.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Dynamic (trait-aware) colour

extension Color {
    /// A colour that resolves to `light` or `dark` based on the active
    /// interface style at draw time. Lets the whole token set follow the
    /// system / user appearance with no churn in consumers.
    static func mixDynamic(light: String, dark: String) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        })
        #else
        return Color(hex: dark)
        #endif
    }
}

// MARK: - Hex Initialiser

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Mixtape Palette

extension Color {

    // MARK: Backgrounds — trait-aware (dark default #121212, light counterparts)
    /// Primary app background
    static let mixBackground   = mixDynamic(light: "#FFFFFF", dark: "#121212")
    /// Elevated surface (cards, bottom sheets)
    static let mixSurface      = mixDynamic(light: "#F2F2F7", dark: "#181818")
    /// Double-elevated surface (modals, context menus)
    static let mixSurface2     = mixDynamic(light: "#E5E5EA", dark: "#282828")
    /// Separator / divider
    static let mixSeparator    = mixDynamic(light: "#D9D9DE", dark: "#2A2A2A")

    // MARK: Brand — user-selectable accent (default vibrant orange)
    /// Primary interactive colour
    static var mixPrimary:     Color { ThemeManager.shared.accent.color }
    /// Primary pressed / darker state
    static var mixPrimaryDark: Color { ThemeManager.shared.accent.darkColor }
    /// Accent — same family as primary
    static var mixAccent:      Color { ThemeManager.shared.accent.color }

    // MARK: Text — trait-aware hierarchy
    static let mixTextPrimary   = mixDynamic(light: "#000000", dark: "#FFFFFF")
    static let mixTextSecondary = mixDynamic(light: "#5C5C5E", dark: "#B3B3B3")
    static let mixTextTertiary  = mixDynamic(light: "#9A9AA0", dark: "#6B6B6B")

    // MARK: Semantic
    static let mixDestructive   = Color(hex: "#E53935")
    static let mixSuccess       = Color(hex: "#1DB954")
    static let mixWarning       = Color(hex: "#F59E0B")

    // MARK: Sync status colours (used in settings UI)
    static let mixSyncPending   = Color(hex: "#F59E0B")
    static let mixSyncConflict  = Color(hex: "#E53935")
    static let mixSyncSynced    = Color(hex: "#1DB954")
}

// MARK: - Gradient Helpers

extension LinearGradient {
    /// Background gradient for artwork headers (dark overlay at bottom)
    static let mixArtworkOverlay = LinearGradient(
        colors: [.clear, Color.mixBackground.opacity(0.95)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Subtle shimmer background for loading placeholders
    static let mixSkeleton = LinearGradient(
        colors: [Color.mixSurface, Color.mixSurface2, Color.mixSurface],
        startPoint: .leading,
        endPoint: .trailing
    )
}
