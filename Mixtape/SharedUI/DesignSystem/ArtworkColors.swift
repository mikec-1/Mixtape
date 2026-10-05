// Dominant colours from artwork: downscale, bucket pixels, return the biggest
// buckets. Falls back to the mix* tokens.

import SwiftUI
import CoreGraphics

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public nonisolated enum ArtworkColors {

    /// Sensible fallback used when artwork is missing or unreadable.
    public static let fallback: [Color] = [
        Color.mixPrimary.opacity(0.45),
        Color.mixBackground
    ]

    /// Up to `count` dominant colours; `fallback` if nothing usable.
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

    /// Colours for a background wash. Buckets are scored by population weighted by
    /// saturation (photos are mostly grey), then clamped to a band that reads as a
    /// colour but stays dark enough for white text. The second colour is another hue
    /// if there is one, else a deeper shade. `[]` when there's no artwork.
    public static func gradientColors(from data: Data?) -> [Color] {
        guard let data, let cg = cgImage(from: data) else { return [] }
        let buckets = extract(from: cg)
        guard !buckets.isEmpty else { return [] }

        let ranked = buckets.sorted { score($0) > score($1) }
        guard let top = ranked.first else { return [] }

        let primary = normalised(top)

        // Minimum hue distance to count as a second colour.
        let minHueGap = 0.07
        let partner = ranked.dropFirst().first { candidate in
            let gap = abs(candidate.hsb.h - top.hsb.h)
            return min(gap, 1 - gap) > minHueGap && candidate.hsb.s > 0.15
        }

        // No second hue: use a deeper shade of the first.
        let secondary = partner.map { normalised($0, brightnessScale: 0.74) }
            ?? Color(hue: top.hsb.h,
                     saturation: min(top.hsb.s + 0.06, 0.62),
                     brightness: max(top.hsb.b * 0.42, 0.14))

        return [primary, secondary]
    }

    /// The first of `gradientColors`.
    public static func gradientTint(from data: Data?) -> Color? {
        gradientColors(from: data).first
    }

    /// Wash for a surface with nothing to sample (e.g. no avatar). The brand accent
    /// run through the same clamp, since raw `mixPrimary` is too strong.
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

    /// Population weighted by saturation. The floor stops a few coloured pixels
    /// beating a monochrome cover.
    private static func score(_ bucket: Bucket) -> Double {
        Double(bucket.count) * (0.35 + bucket.hsb.s)
    }

    /// Clamps a sample into backdrop range: vivid enough to read as colour, dark
    /// enough for white text. Near-greys stay neutral. Kept narrow since this also
    /// tints the titlebar.
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

    /// One RGB cube cell: pixel count and average colour in RGB and HSB.
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

        /// HSB, all 0...1. Hand-rolled to avoid UIKit/AppKit.
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
        // Small fixed grid is enough for averaging.
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

        // 4x4x4 RGB buckets with summed components for the average.
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
