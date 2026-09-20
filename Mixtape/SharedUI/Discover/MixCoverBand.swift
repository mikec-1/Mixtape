// MixCoverBand.swift
// Mixtape — SharedUI/Discover
//
// The colour a mix wears, and the band it wears it on.
//
// Four album covers arranged in a square is accurate but drab: every mix looks
// like every other mix, and next to an album grid they don't read as places.
// Spotify solves it by painting the mix its own colour and printing the name on
// it. Same here — with the colour derived from the mix's id, so a mix keeps the
// same colour on the landing, on its page, and next week when it's rebuilt from
// the same seed.

import SwiftUI

enum MixCoverStyle {

    /// Deliberately literal rather than themed: this is the one place in the app
    /// that's supposed to be loud, and a token would follow the appearance and
    /// stop being the mix's own colour.
    private static let palette: [(r: Double, g: Double, b: Double)] = [
        (0.91, 0.25, 0.33),   // red
        (0.95, 0.48, 0.14),   // orange
        (0.20, 0.60, 0.44),   // green
        (0.16, 0.44, 0.78),   // blue
        (0.55, 0.28, 0.75),   // purple
        (0.89, 0.36, 0.60),   // pink
        (0.10, 0.55, 0.60),   // teal
        (0.75, 0.58, 0.12)    // gold
    ]

    /// The raw components, so the baked cover (`MixCoverArt`) can paint the same
    /// band in Core Graphics that the card paints in SwiftUI.
    static func rgb(for id: String) -> (r: Double, g: Double, b: Double) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func color(for id: String) -> Color {
        let c = rgb(for: id)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// The gradient band with the mix's name, drawn over the bottom of its mosaic.
struct MixCoverBand: View {

    let title: String
    let accent: Color
    /// The cover's edge length — everything here scales off it so one band works
    /// for a 168pt card and a 260pt hero.
    let side: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: max(11, side * 0.105), weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, side * 0.06)
                .padding(.bottom, side * 0.055)
                .padding(.top, side * 0.16)
                .background(
                    LinearGradient(colors: [accent.opacity(0), accent.opacity(0.92), accent],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}
