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
        guard let colors = extract(from: cg, count: count), !colors.isEmpty else {
            return fallback
        }
        return colors
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

    private static func extract(from image: CGImage, count: Int) -> [Color]? {
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
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Bucket colours into a coarse 4x4x4 RGB cube; track count + summed
        // components so we can return the bucket's average colour.
        struct Bucket { var count = 0; var r = 0.0; var g = 0.0; var b = 0.0 }
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

        guard !buckets.isEmpty else { return nil }

        let sorted = buckets.values
            .sorted { $0.count > $1.count }
            .prefix(count)

        return sorted.map { bucket in
            let n = Double(bucket.count)
            return Color(
                .sRGB,
                red: (bucket.r / n) / 255.0,
                green: (bucket.g / n) / 255.0,
                blue: (bucket.b / n) / 255.0,
                opacity: 1.0
            )
        }
    }
}
