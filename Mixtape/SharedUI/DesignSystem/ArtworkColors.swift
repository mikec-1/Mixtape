// ArtworkColors.swift
// Mixtape — Design System
//
// Cheap dominant-colour extraction from album artwork.
// Downscales the artwork to a tiny bitmap and quantizes pixels into a few
// colour buckets, returning the most populous buckets as SwiftUI Colors.
//
// Cross-platform: UIImage on iOS, NSImage elsewhere.
// Falls back to the mix* design tokens when no usable colour is found.

import SwiftUI
import CoreGraphics

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public enum ArtworkColors {

    /// Sensible fallback used when artwork is missing or unreadable.
    public static let fallback: [Color] = [
        Color.mixPrimary.opacity(0.45),
        Color.mixBackground
    ]

    /// Extracts up to `count` dominant colours from artwork `Data`.
    /// Returns `fallback` if the data is nil/undecodable or yields no colour.
    public static func dominantColors(from data: Data?, count: Int = 3) -> [Color] {
        guard let data, let cg = cgImage(from: data) else { return fallback }
        let buckets = extract(from: cg)
        guard !buckets.isEmpty else { return fallback }
        return buckets
            .sorted { $0.count > $1.count }
            .prefix(count)
            .map { $0.color }
    }

    // MARK: - Gradient palette

    /// Colours picked for how well they read as a background wash, which is not
    /// the same question as "which colour covers the most pixels".
    ///
    /// A playlist cover made of photographs is mostly skin, asphalt and overcast
    /// sky: the largest bucket wins on count and produces the lifeless grey
    /// wash. So buckets are scored by population *weighted by saturation*, and
    /// the winner is then pulled into a band that still reads as a colour while
    /// staying dark enough for white text to sit on top.
    ///
    /// The second colour is a different hue where the artwork has one, so the
    /// gradient has somewhere to travel; otherwise it's a deeper shade of the
    /// first. Returns `[]` when the artwork is missing or unreadable, so callers
    /// can skip the wash entirely rather than paint a fake one.
    public static func gradientColors(from data: Data?) -> [Color] {
        guard let data, let cg = cgImage(from: data) else { return [] }
        let buckets = extract(from: cg)
        guard !buckets.isEmpty else { return [] }

        let ranked = buckets.sorted { score($0) > score($1) }
        guard let top = ranked.first else { return [] }

        let primary = normalised(top)

        // A hue at least this far away reads as a second colour rather than as
        // a compression artefact of the first.
        let minHueGap = 0.07
        let partner = ranked.dropFirst().first { candidate in
            let gap = abs(candidate.hsb.h - top.hsb.h)
            return min(gap, 1 - gap) > minHueGap && candidate.hsb.s > 0.15
        }

        // No second hue in the artwork — a deeper shade of the first still gives
        // the gradient somewhere to go.
        let secondary = partner.map { normalised($0, brightnessScale: 0.74) }
            ?? Color(hue: top.hsb.h,
                     saturation: min(top.hsb.s + 0.06, 0.62),
                     brightness: max(top.hsb.b * 0.42, 0.14))

        return [primary, secondary]
    }

    /// Single wash colour — the first of `gradientColors`.
    public static func gradientTint(from data: Data?) -> Color? {
        gradientColors(from: data).first
    }

    /// The wash for a surface that must be tinted even when there's nothing to
    /// sample — a profile whose owner never set an avatar, say.
    ///
    /// Built by running the brand accent through the same clamping real artwork
    /// gets, rather than reaching for the raw token: `mixPrimary` is a full-
    /// strength control colour, and a page washed in it at the strength a
    /// sampled colour uses looks like a rendering fault. Derived from
    /// `BrandAccent.hex` so it still follows if the brand colour ever moves.
    public static var brandGradient: [Color] {
        let digits = BrandAccent.hex.drop { !$0.isHexDigit }
        let packed = UInt32(digits, radix: 16) ?? 0xFF6B00
        var bucket = Bucket()
        bucket.count = 1
        bucket.r = Double((packed >> 16) & 0xFF)
        bucket.g = Double((packed >> 8)  & 0xFF)
        bucket.b = Double( packed        & 0xFF)
        return [normalised(bucket), normalised(bucket, brightnessScale: 0.62)]
    }

    /// Population weighted by how colourful the bucket is. The floor keeps a
    /// genuinely monochrome cover (a black-and-white photo, a plain-text sleeve)
    /// from being beaten by a handful of stray coloured pixels.
    private static func score(_ bucket: Bucket) -> Double {
        Double(bucket.count) * (0.35 + bucket.hsb.s)
    }

    /// Clamps a sampled colour into the range that works as a backdrop: vivid
    /// enough not to look like a rendering bug, dark enough for white text.
    /// Near-grey samples keep their neutrality instead of having a hue invented
    /// for them — an invented hue is always the wrong one.
    /// The bands are deliberately narrow. A wash reads as a mistake long before
    /// it reads as dull, and this colour now runs behind the window titlebar as
    /// well, where a vivid tint looks like a rendering bug rather than a choice.
    private static func normalised(_ bucket: Bucket, brightnessScale: Double = 1.0) -> Color {
        let hsb = bucket.hsb
        let isNeutral = hsb.s < 0.08
        let saturation = isNeutral ? hsb.s : min(max(hsb.s, 0.28), 0.62)
        let brightness = min(max(hsb.b, 0.26), 0.48) * brightnessScale
        return Color(hue: hsb.h, saturation: saturation, brightness: brightness)
    }

    // MARK: - Decoding

    private static func cgImage(from data: Data) -> CGImage? {
        #if os(iOS)
        return UIImage(data: data)?.cgImage
        #else
        guard let ns = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    // MARK: - Quantization

    /// One cell of the RGB cube: how many pixels landed in it and their average
    /// colour, in both RGB and HSB (selection reasons about hue and saturation,
    /// drawing needs the colour).
    struct Bucket {
        var count = 0
        var r = 0.0, g = 0.0, b = 0.0

        /// Average channel values, 0...1.
        var rgb: (r: Double, g: Double, b: Double) {
            let n = Double(max(count, 1))
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        var color: Color {
            let c = rgb
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
        }

        /// Hue/saturation/brightness, all 0...1. Hand-rolled so the type stays
        /// free of UIKit/AppKit and usable from any platform.
        var hsb: (h: Double, s: Double, b: Double) {
            let c = rgb
            let maxC = max(c.r, max(c.g, c.b))
            let minC = min(c.r, min(c.g, c.b))
            let delta = maxC - minC
            guard delta > 0.0001 else { return (0, 0, maxC) }

            var hue: Double
            switch maxC {
            case c.r: hue = (c.g - c.b) / delta
            case c.g: hue = 2 + (c.b - c.r) / delta
            default:  hue = 4 + (c.r - c.g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
            return (hue, delta / maxC, maxC)
        }
    }

    private static func extract(from image: CGImage) -> [Bucket] {
        // Downscale to a small fixed grid — cheap and plenty for averaging.
        let dim = 24
        let width = dim
        let height = dim
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return [] }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Bucket colours into a coarse 4x4x4 RGB cube; track count + summed
        // components so we can return the bucket's average colour.
        var buckets: [Int: Bucket] = [:]

        var i = 0
        let total = width * height
        while i < total {
            let o = i * bytesPerPixel
            let a = Int(pixels[o + 3])
            i += 1
            if a < 16 { continue } // skip near-transparent

            let r = Int(pixels[o])
            let g = Int(pixels[o + 1])
            let b = Int(pixels[o + 2])

            // Skip near-black / near-white so backgrounds stay vibrant.
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            if maxC < 24 { continue }            // basically black
            if minC > 235 { continue }           // basically white

            let key = (r >> 6) << 4 | (g >> 6) << 2 | (b >> 6)
            var bucket = buckets[key] ?? Bucket()
            bucket.count += 1
            bucket.r += Double(r)
            bucket.g += Double(g)
            bucket.b += Double(b)
            buckets[key] = bucket
        }

        return Array(buckets.values)
    }
}
