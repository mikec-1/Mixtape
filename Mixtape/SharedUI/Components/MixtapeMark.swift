// MixtapeMark.swift
// Mixtape — SharedUI/Components
//
// The app's own mark, wherever the app has to sign something.

import SwiftUI

/// Mixtape, drawn as itself.
///
/// The same waveform the launch screen shows, at whatever size the caller asks
/// for, so the app has one mark rather than a different idea of itself on every
/// screen. It signs the mixes it builds: the Mixtape profile, the byline on a
/// mix, and the cover of a saved mix that hasn't got artwork of its own yet.
///
/// The glyph is a filled circle with the waveform knocked out of it, which is why
/// nothing here draws a circle behind it — the symbol *is* the circle, and a
/// backdrop would fill in the one part that's meant to be seen through.
public struct MixtapeMark: View {

    /// Named once, because a symbol that doesn't exist fails quietly: SwiftUI
    /// renders an empty frame and only the console mentions it. `cassette.fill`
    /// reads perfectly, shipped in three places, and is not a symbol.
    public static let symbolName = "waveform.circle.fill"

    private let size: CGFloat
    private let style: AnyShapeStyle

    /// The mark in the app's own colour — flat `mixPrimary`, which is how the
    /// launch screen and both sign-in screens have always drawn it. Not a
    /// gradient: the gradient belonged to the circle this replaced, and the mark
    /// is meant to be the same object everywhere it appears.
    public init(size: CGFloat) {
        self.init(size: size, style: Color.mixPrimary)
    }

    /// The mark in some other fill — white, where it sits on colour of its own.
    public init(size: CGFloat, style: some ShapeStyle) {
        self.size  = size
        self.style = AnyShapeStyle(style)
    }

    public var body: some View {
        Image(systemName: Self.symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(style)
    }
}
