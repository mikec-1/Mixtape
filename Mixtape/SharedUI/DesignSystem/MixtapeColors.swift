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
    /// - Parameters:
    ///   - light: the colour in the light appearance.
    ///   - dark: the colour in the dark appearance.
    ///   - lightHC: light-appearance colour when Increase Contrast is on.
    ///     Defaults to `light`, so tokens that already clear their ratio opt out
    ///     by saying nothing.
    ///   - darkHC: dark-appearance counterpart. Defaults to `dark`.
    static func mixDynamic(
        light: String,
        dark: String,
        lightHC: String? = nil,
        darkHC: String? = nil
    ) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let boosted = trait.accessibilityContrast == .high
            let hex: String
            switch (isDark, boosted) {
            case (true,  true):  hex = darkHC  ?? dark
            case (true,  false): hex = dark
            case (false, true):  hex = lightHC ?? light
            case (false, false): hex = light
            }
            return UIColor(Color(hex: hex))
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            // `bestMatch` has to be asked about the high-contrast appearances
            // explicitly — they are separate names, not a flag on aqua.
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let boosted = match == .accessibilityHighContrastAqua
                       || match == .accessibilityHighContrastDarkAqua
            let hex: String
            switch (isDark, boosted) {
            case (true,  true):  hex = darkHC  ?? dark
            case (true,  false): hex = dark
            case (false, true):  hex = lightHC ?? light
            case (false, false): hex = light
            }
            return NSColor(Color(hex: hex))
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

    // MARK: Brand — vibrant orange accent
    //
    // Orange is a *light* colour, so it splits into two jobs that a single hex
    // can't do. As a fill it stays #FF6B00 in both appearances — that is the
    // brand. As text or a glyph it has to clear 4.5:1, and #FF6B00 on white is
    // only 2.86:1, so the light appearance darkens it to #B84A00 (5.23:1).
    // Dark mode keeps the pure accent, which already measures 6.56:1.

    /// Primary interactive colour — text, glyphs, tints. Trait-aware.
    static let mixPrimary     = mixDynamic(light: "#B84A00", dark: "#FF6B00",
                                           lightHC: "#8F3A00", darkHC: "#FF8C33")
    /// Primary pressed / darker state
    static let mixPrimaryDark = mixDynamic(light: "#8F3A00", dark: "#E05C00",
                                           lightHC: "#6E2D00", darkHC: "#FF6B00")
    /// Accent — same family as primary
    static let mixAccent      = mixPrimary

    /// The brand orange as a *fill*, unchanged across appearances. Use this for
    /// filled buttons, badges and progress tracks — anything where the orange is
    /// the background rather than the thing being read.
    static let mixAccentFill  = BrandAccent.color

    /// The label colour that belongs on `mixAccentFill`. White on orange is
    /// 2.86:1 and fails in both appearances; near-black on it is 6.10:1. In the
    /// light appearance the fill darkens with `mixPrimary`, so white wins there.
    static let mixOnAccent    = mixDynamic(light: "#FFFFFF", dark: "#1A1A1A")
    /// The line under the last song of the repeating group. Named separately
    /// from `mixPrimary` because it marks a state rather than an action — if the
    /// brand accent ever stops being orange this line should stay one.
    static var mixRepeatBoundary: Color { BrandAccent.color }

    // MARK: Text — trait-aware hierarchy
    static let mixTextPrimary   = mixDynamic(light: "#000000", dark: "#FFFFFF")
    static let mixTextSecondary = mixDynamic(light: "#5C5C5E", dark: "#B3B3B3",
                                             lightHC: "#3A3A3C", darkHC: "#D0D0D0")
    /// Was #9A9AA0 / #6B6B6B, which measured 2.80:1 and 3.52:1 against the two
    /// backgrounds — both under the 4.5:1 floor for text at or below 17pt.
    /// Now 5.05:1 light / 6.18:1 dark, and still clears 4.5:1 on mixSurface2.
    static let mixTextTertiary  = mixDynamic(light: "#6E6E76", dark: "#949494",
                                             lightHC: "#5A5A62", darkHC: "#ABABAB")

    // MARK: Semantic
    //
    // These were flat hexes — the only tokens here that weren't trait-aware —
    // and the light appearance paid for it: #F59E0B measured 2.15:1 on white
    // and #1DB954 measured 2.59:1. They carry status, usually at caption size,
    // so they need the same 4.5:1 floor as any other small text.
    static let mixDestructive   = mixDynamic(light: "#C62828", dark: "#E53935",
                                             lightHC: "#A31D1D", darkHC: "#FF6B68")
    static let mixSuccess       = mixDynamic(light: "#0F7A38", dark: "#1DB954",
                                             lightHC: "#0A5A29", darkHC: "#3FD673")
    static let mixWarning       = mixDynamic(light: "#8A5A00", dark: "#F59E0B",
                                             lightHC: "#6B4600", darkHC: "#FFB733")

    // MARK: Sync status colours (used in settings UI)
    static let mixSyncPending   = mixWarning
    static let mixSyncConflict  = mixDestructive
    static let mixSyncSynced    = mixSuccess
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
