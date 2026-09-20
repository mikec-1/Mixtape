// MixtapeTypography.swift
// Mixtape — Design System

import SwiftUI

// MARK: - Scalable sizing
//
// The tiers below are deliberate point sizes, not the system text styles, and
// remapping them onto `.body`/`.title` would quietly redesign the app — 15pt
// body would become 17pt, and every row height with it.
//
// So the sizes stay, and each one is instead *scaled* by the same metrics the
// system applies to its own text styles. Each tier names the style whose growth
// curve it should follow: display text grows more slowly than body text, which
// is why a single multiplier would be wrong.
//
// These are computed `var`s rather than `let`s on purpose. Reading one asks the
// system for the current size category, and SwiftUI re-evaluates a view's body
// when that category changes, so the fonts follow along with no observer.
//
// macOS has no equivalent setting — the platform doesn't offer scalable text —
// so there the sizes resolve to exactly what's written.

#if canImport(UIKit)
import UIKit
#endif

enum MixFontScale {
    #if canImport(UIKit)
    static func size(_ points: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: points)
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
//
// One typeface, top to bottom: SF Pro.
//
// The display tiers used to be SF Pro *Rounded*, which is the face Apple ships
// for watchOS and for apps aimed at children. Against dark, dense track lists it
// read as a toy, and it sat oddly beside body copy that was plain SF all along —
// the headings looked bolted on rather than part of a scale.
//
// Contrast now comes from size and weight, the way it does in every serious
// media app. Above 20pt the system silently swaps to SF Pro Display, which is
// drawn tighter and with finer detail than the text cut, so the big tiers get
// their authority from the typeface doing its job rather than from a novelty.

extension Font {
    // MARK: Display / Hero
    /// 34pt bold — screen titles, artist names in header. Pair with `.mixTightened()`.
    static var mixDisplay:     Font { .system(size: MixFontScale.size(34, mixLargeTitle), weight: .bold) }
    /// 28pt bold — album titles, large section headers
    static var mixHeadline:    Font { .system(size: MixFontScale.size(28, mixTitle1), weight: .bold) }
    /// 22pt semibold — section headings, sheet titles
    static var mixTitle:       Font { .system(size: MixFontScale.size(22, mixTitle2S), weight: .semibold) }
    /// 18pt semibold — list section headers, tab names
    static var mixTitle2:      Font { .system(size: MixFontScale.size(18, mixTitle3), weight: .semibold) }

    // MARK: Body
    /// 15pt regular — primary body copy, track titles
    static var mixBody:        Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .regular) }
    /// 15pt semibold — emphasis in body copy
    static var mixBodyBold:    Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .semibold) }
    /// 13pt medium — secondary info (artist name in row, duration)
    static var mixLabel:       Font { .system(size: MixFontScale.size(13, mixFootnote), weight: .medium) }
    /// 13pt regular — subtext
    static var mixSubtext:     Font { .system(size: MixFontScale.size(13, mixFootnote), weight: .regular) }

    // MARK: Caption
    /// 11pt medium — captions, badge text
    static var mixCaption:     Font { .system(size: MixFontScale.size(11, mixCaption1), weight: .medium) }
    /// 11pt semibold — bold captions, section headers
    static var mixCaptionBold: Font { .system(size: MixFontScale.size(11, mixCaption1), weight: .semibold) }
    /// 10pt regular — fine print, sync status
    static var mixMicro:       Font { .system(size: MixFontScale.size(10, mixCaption2), weight: .regular) }

    // MARK: Interactive
    /// 15pt semibold — primary buttons
    static var mixButton:      Font { .system(size: MixFontScale.size(15, mixBodyS), weight: .semibold) }
    /// 13pt semibold — small / secondary buttons, chips
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

    /// Pulls display-size text in the way a set wordmark is set.
    ///
    /// SF's optical sizing already tightens large text, but only to the point
    /// where it reads as body copy scaled up. The last half-point is what makes
    /// a title look chosen rather than defaulted, and it's why "Mixtape" on the
    /// splash needs no ornament to hold the screen.
    ///
    /// A view modifier rather than part of the `Font`, because SwiftUI's `Font`
    /// has nowhere to carry tracking. Use it on 28pt and up; below that SF Text
    /// is already spaced for reading and tightening only hurts legibility.
    func mixTightened() -> some View {
        tracking(-0.6)
    }
}
