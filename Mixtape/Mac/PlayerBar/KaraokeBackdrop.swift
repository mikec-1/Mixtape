// KaraokeBackdrop.swift
// Mixtape — Mac/PlayerBar
//
// The full-window background of karaoke mode: the album's colours, with a
// handful of blooms of them drifting across so the screen is never quite still.
//
// It is painted by the root rather than by the lyrics view because the player
// bar and top bar fade out in karaoke, and a background that stopped where the
// lyrics stopped left black bands where those bars had been.
//
// Flat layers and nothing else: no `.blur`, no blend modes, no image.
// A blur wide enough to matter on a full-screen view is a per-frame filter over
// the whole window and it stalled the main thread hard enough to stop the
// audio; a scaled-up thumbnail costs nothing but looks like a scaled-up
// thumbnail; `plusLighter` forces the whole stack through an offscreen pass on
// every frame of the drift. What's left is gradients moving on transforms,
// which is the one version of this that is free.

#if os(macOS)
import SwiftUI

struct KaraokeBackdrop: View {

    @EnvironmentObject private var queueService: QueueService

    /// Up to five colours off the cover, saturated up. More than the two the
    /// gradient used to have: a cover's second and third buckets are usually
    /// neighbours of the first, so a two-stop wash reads as one flat colour.
    @State private var palette: [Color] = []
    @State private var breathing = false
    @State private var drift = false
    @State private var swirl = false

    private var base: [Color] {
        palette.isEmpty ? [Color(white: 0.16), Color(white: 0.10)]
                        : [palette[0], palette.count > 1 ? palette[1] : palette[0]]
    }

    /// Colour for bloom `i`, wrapping round the palette so a one-colour cover
    /// still gets light and dark blooms rather than three identical discs.
    private func bloomColor(_ i: Int, lift: Double) -> Color {
        let source = palette.isEmpty ? Color(white: 0.3) : palette[i % palette.count]
        return Self.vivid(source, brightness: lift)
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: base, startPoint: .topLeading, endPoint: .bottomTrailing)

                bloom(bloomColor(0, lift: 1.9), side: side * 1.2, opacity: 0.85)
                    .offset(x: breathing ? side * 0.26 : -side * 0.28,
                            y: breathing ? -side * 0.22 : side * 0.20)

                bloom(bloomColor(1, lift: 1.5), side: side * 1.0, opacity: 0.8)
                    .offset(x: drift ? -side * 0.30 : side * 0.24,
                            y: drift ? side * 0.24 : -side * 0.26)

                bloom(bloomColor(2, lift: 1.7), side: side * 0.85, opacity: 0.75)
                    .offset(x: swirl ? side * 0.30 : -side * 0.10,
                            y: swirl ? side * 0.28 : -side * 0.30)

                // A dark bloom rather than a full-screen scrim: it keeps the
                // corners deep for the type without draining the whole wash.
                bloom(bloomColor(3, lift: 0.30), side: side * 1.1, opacity: 0.7)
                    .offset(x: drift ? side * 0.22 : -side * 0.22,
                            y: breathing ? side * 0.26 : -side * 0.18)

                Color.black.opacity(0.16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .ignoresSafeArea()
        .mixAnimation(.easeInOut(duration: 0.5), value: palette)
        .onAppear {
            refresh()
            withMixAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true))  { breathing = true }
            withMixAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) { drift = true }
            withMixAnimation(.easeInOut(duration: 17).repeatForever(autoreverses: true)) { swirl = true }
        }
        // An explicit zero-duration transaction: a `repeatForever` left attached
        // to a view being torn down keeps animating it.
        .onDisappear {
            withAnimation(.linear(duration: 0)) { breathing = false; drift = false; swirl = false }
        }
        .onChange(of: queueService.currentTrack?.id) { _, _ in refresh() }
    }

    private func bloom(_ color: Color, side: CGFloat, opacity: Double) -> some View {
        RadialGradient(colors: [color.opacity(0.9), color.opacity(0)],
                       center: .center, startRadius: 0, endRadius: side / 2)
            .frame(width: side, height: side)
            .opacity(opacity)
    }

    /// Pushes a cover colour to a brightness the wash can use, saturating it on
    /// the way: covers are mastered dark and a straight sample of one is mud.
    private static func vivid(_ color: Color, brightness factor: Double) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h),
                     saturation: min(1, max(0.35, Double(s) * (factor > 1 ? 1.35 : 1.1))),
                     brightness: min(0.95, max(0.05, Double(b) * factor)))
    }

    /// The wash as the bottom of the window sees it, for chrome that has to sit
    /// on the backdrop and can't be transparent (the player bar has the lyrics
    /// scrolling underneath it). Same palette, same saturation push — so the bar
    /// reads as part of the gradient instead of a slab laid over it.
    static func chromeTint(for artwork: Data?) -> Color {
        let palette = ArtworkColors.dominantColors(from: artwork, count: 5)
        guard let first = palette.first else { return Color(white: 0.12) }
        return blend(vivid(palette.count > 1 ? palette[1] : first, brightness: 1.25),
                     vivid(first, brightness: 0.55))
    }

    private static func blend(_ a: Color, _ b: Color) -> Color {
        guard let x = NSColor(a).usingColorSpace(.deviceRGB),
              let y = NSColor(b).usingColorSpace(.deviceRGB) else { return a }
        return Color(nsColor: NSColor(red:   (x.redComponent   + y.redComponent)   / 2,
                                     green: (x.greenComponent + y.greenComponent) / 2,
                                     blue:  (x.blueComponent  + y.blueComponent)  / 2,
                                     alpha: 1))
    }

    private func refresh() {
        palette = ArtworkColors.dominantColors(from: queueService.currentTrack?.displayArtwork, count: 5)
    }
}

#endif
