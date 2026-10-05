// Colour tokens: dark base, orange accent. Use as Color.mixPrimary etc.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Dynamic (trait-aware) colour

nonisolated extension Color {
    /// A colour that resolves for the current appearance at draw time.
    /// - Parameters:
    /// - light: light appearance.
    /// - dark: dark appearance.
    /// - lightHC: light with Increase Contrast. Defaults to `light`.
    /// - darkHC: dark with Increase Contrast. Defaults to `dark`.
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
            // High-contrast appearances are separate names and must be asked for.
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

nonisolated extension Color {
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

nonisolated extension Color {

    // MARK: Backgrounds: trait-aware (dark default #121212, light counterparts)
    /// Primary app background
    static let mixBackground   = mixDynamic(light: "#FFFFFF", dark: "#121212")
    /// Elevated surface (cards, bottom sheets)
    static let mixSurface      = mixDynamic(light: "#F2F2F7", dark: "#181818")
    /// Double-elevated surface (modals, context menus)
    static let mixSurface2     = mixDynamic(light: "#E5E5EA", dark: "#282828")
    /// Separator / divider
    static let mixSeparator    = mixDynamic(light: "#D9D9DE", dark: "#2A2A2A")

    // MARK: Brand: vibrant orange accent
    // Orange as a fill stays #FF6B00. As text it needs 4.5:1, so light mode
    // darkens it to #B84A00.

    /// Primary interactive colour for text, glyphs, tints.
    static let mixPrimary     = mixDynamic(light: "#B84A00", dark: "#FF6B00",
                                           lightHC: "#8F3A00", darkHC: "#FF8C33")
    /// Primary pressed / darker state
    static let mixPrimaryDark = mixDynamic(light: "#8F3A00", dark: "#E05C00",
                                           lightHC: "#6E2D00", darkHC: "#FF6B00")
    /// Same as primary.
    static let mixAccent      = mixPrimary

    /// Brand orange as a fill, same in both appearances. Buttons, badges, progress.
    static let mixAccentFill  = BrandAccent.color

    /// Label colour on `mixAccentFill`; white on orange fails contrast.
    static let mixOnAccent    = mixDynamic(light: "#FFFFFF", dark: "#1A1A1A")
    /// Line under the last song of the repeating group. Separate from `mixPrimary`
    /// since it marks a state, not an action.
    static var mixRepeatBoundary: Color { BrandAccent.color }

    // MARK: Text: trait-aware hierarchy
    static let mixTextPrimary   = mixDynamic(light: "#000000", dark: "#FFFFFF")
    static let mixTextSecondary = mixDynamic(light: "#5C5C5E", dark: "#B3B3B3",
                                             lightHC: "#3A3A3C", darkHC: "#D0D0D0")
    /// Clears 4.5:1 on both backgrounds and mixSurface2.
    static let mixTextTertiary  = mixDynamic(light: "#6E6E76", dark: "#949494",
                                             lightHC: "#5A5A62", darkHC: "#ABABAB")

    // MARK: Semantic
    // Status colours, often caption-sized, so trait-aware and 4.5:1 like other text.
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
