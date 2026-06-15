// MixtapeTypography.swift
// Mixtape — Design System

import SwiftUI

// MARK: - Font Scale

extension Font {
    // MARK: Display / Hero
    /// 34pt bold rounded — screen titles, artist names in header
    static let mixDisplay      = Font.system(size: 34, weight: .bold,     design: .rounded)
    /// 28pt bold rounded — album titles, large section headers
    static let mixHeadline     = Font.system(size: 28, weight: .bold,     design: .rounded)
    /// 22pt semibold rounded — section headings, sheet titles
    static let mixTitle        = Font.system(size: 22, weight: .semibold, design: .rounded)
    /// 18pt semibold rounded — list section headers, tab names
    static let mixTitle2       = Font.system(size: 18, weight: .semibold, design: .rounded)

    // MARK: Body
    /// 15pt regular — primary body copy, track titles
    static let mixBody         = Font.system(size: 15, weight: .regular,  design: .default)
    /// 15pt semibold — emphasis in body copy
    static let mixBodyBold     = Font.system(size: 15, weight: .semibold, design: .default)
    /// 13pt medium — secondary info (artist name in row, duration)
    static let mixLabel        = Font.system(size: 13, weight: .medium,   design: .default)
    /// 13pt regular — subtext
    static let mixSubtext      = Font.system(size: 13, weight: .regular,  design: .default)

    // MARK: Caption
    /// 11pt medium — captions, badge text
    static let mixCaption      = Font.system(size: 11, weight: .medium,   design: .default)
    /// 11pt semibold — bold captions, section headers
    static let mixCaptionBold  = Font.system(size: 11, weight: .semibold, design: .default)
    /// 10pt regular — fine print, sync status
    static let mixMicro        = Font.system(size: 10, weight: .regular,  design: .default)

    // MARK: Interactive
    /// 15pt semibold — primary buttons
    static let mixButton       = Font.system(size: 15, weight: .semibold, design: .default)
    /// 13pt semibold — small / secondary buttons, chips
    static let mixButtonSmall  = Font.system(size: 13, weight: .semibold, design: .default)
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
}
