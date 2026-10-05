import SwiftUI

// MARK: - Scalable sizing
// Fixed point sizes, not system text styles (remapping would change row
// heights). Each tier scales with Dynamic Type using the growth curve of a named
// style. Computed `var`s so they re-read the size category. macOS has no
// Dynamic Type, so sizes are exact there.

#if canImport(UIKit)
import UIKit
#endif

enum MixFontScale {
    #if canImport(UIKit)
    static func size(_ points: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: points)
    }

    /// Scales a one-off size using the nearest tier's curve. For the long tail of
    /// hardcoded sizes; name a style directly for real tiers.
    static func size(_ points: CGFloat) -> CGFloat {
        let style: UIFont.TextStyle
        switch points {
        case 31...:      style = .largeTitle
        case 25..<31:    style = .title1
        case 20..<25:    style = .title2
        case 16.5..<20:  style = .title3
        case 14..<16.5:  style = .body
        case 12..<14:    style = .footnote
        case 10.5..<12:  style = .caption1
        default:         style = .caption2
        }
        return size(points, style)
    }
    #else
    static func size(_ points: CGFloat, _ style: Int = 0) -> CGFloat { points }
    #endif
}

#if canImport(UIKit)
private typealias MixTextStyle = UIFont.TextStyle
private let mixLargeTitle: MixTextStyle = .largeTitle
private let mixTitle1:     MixTextStyle = .title1
private let mixTitle2S:    MixTextStyle = .title2
private let mixTitle3:     MixTextStyle = .title3
private let mixBodyS:      MixTextStyle = .body
private let mixFootnote:   MixTextStyle = .footnote
private let mixCaption1:   MixTextStyle = .caption1
private let mixCaption2:   MixTextStyle = .caption2
#else
private let mixLargeTitle = 0, mixTitle1 = 0, mixTitle2S = 0, mixTitle3 = 0
private let mixBodyS = 0, mixFootnote = 0, mixCaption1 = 0, mixCaption2 = 0
#endif

// MARK: - Font Scale
// SF Pro throughout. Contrast comes from size and weight; above 20pt the
// system uses SF Pro Display.

extension Font {
    // MARK: Display / Hero
    /// 34pt bold: screen titles, artist names. Pair with `.mixTightened()`.
    static var mixDisplay:     Font { .system(size: MixFontScale.size(34, mixLargeTitle), weight: .bold) }
    /// 28pt bold: album titles, large section headers.
    static var mixHeadline:    Font { .system(size: MixFontScale.size(28, mixTitle1), weight: .bold) }
    /// 22pt semibold: section headings, sheet titles.
    static var mixTitle:       Font { .system(size: MixFontScale.size(22, mixTitle2S), weight: .semibold) }
    /// 18pt semibold: list section headers, tab names.
    static var mixTitle2:      Font { .system(size: MixFontScale.size(18, mixTitle3), weight: .semibold) }

    // MARK: Body
    /// 15pt regular: body copy, track titles.
    static var mixBody:        Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .regular) }
    /// 15pt semibold: body emphasis.
    static var mixBodyBold:    Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .semibold) }
    /// 13pt medium: secondary info (artist, duration).
    static var mixLabel:       Font { .system(size: MixFontScale.size(13, mixFootnote), weight: .medium) }
    /// 13pt regular: subtext.
    static var mixSubtext:     Font { .system(size: MixFontScale.size(13, mixFootnote), weight: .regular) }

    // MARK: Caption
    /// 11pt medium: captions, badges.
    static var mixCaption:     Font { .system(size: MixFontScale.size(11, mixCaption1), weight: .medium) }
    /// 11pt semibold: bold captions, section headers.
    static var mixCaptionBold: Font { .system(size: MixFontScale.size(11, mixCaption1), weight: .semibold) }
    /// 10pt regular: fine print, sync status.
    static var mixMicro:       Font { .system(size: MixFontScale.size(10, mixCaption2), weight: .regular) }

    // MARK: Interactive
    /// 15pt semibold: primary buttons.
    static var mixButton:      Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .semibold) }
    /// 13pt semibold: small buttons, chips.
    static var mixButtonSmall: Font { .system(size: MixFontScale.size(13, mixFootnote), weight: .semibold) }
}

// MARK: - Text Style View Modifier

struct MixtapeTextStyle: ViewModifier {
    let font: Font
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(font)
            .foregroundStyle(color)
    }
}

extension View {
    func mixStyle(_ font: Font, color: Color = .mixTextPrimary) -> some View {
        modifier(MixtapeTextStyle(font: font, color: color))
    }

    /// Slightly tighter tracking for display text. A modifier because `Font` can't
    /// carry tracking. Use at 28pt and up.
    func mixTightened() -> some View {
        tracking(-0.6)
    }
}
