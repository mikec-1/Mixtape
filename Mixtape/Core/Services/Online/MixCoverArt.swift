// MixCoverArt.swift
// Mixtape — Core/Services/Online
//
// The 2×2 mosaic a mix wears, baked into a single image.
//
// On the Discover page a mix's cover is four remote images arranged by SwiftUI.
// A library playlist can't wear that: it has one `artworkData`, and everything
// that draws a playlist — the sidebar, the library grid, search results, the
// Mac command palette — reads exactly that field. So a saved mix arrived with
// nothing and fell back to the generic playlist glyph, which is the one cover
// it definitely shouldn't have had.
//
// Flattening the mosaic here is what makes the saved copy look like the thing
// that was saved, everywhere, without teaching a dozen views what a mix is.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

public enum MixCoverArt {

    /// Downloads up to four covers and composes them into one square JPEG.
    ///
    /// Nil when nothing could be fetched — the caller leaves the playlist's
    /// cover alone rather than writing a blank tile over it.
    /// The colour band a mix wears on its cover, baked in.
    ///
    /// Saved mixes keep the look they had on the Discover card — a plain 2×2 in
    /// the library next to a banded card on Discover read as two different
    /// playlists. Library playlists pass nil and stay plain.
    public struct Band: Sendable {
        let title: String
        let red:   Double
        let green: Double
        let blue:  Double

        public init(title: String, rgb: (r: Double, g: Double, b: Double)) {
            self.title = title
            self.red = rgb.r; self.green = rgb.g; self.blue = rgb.b
        }
    }

    static func compose(from urls: [URL], side: Int = 640, band: Band? = nil) async -> Data? {
        var seen = Set<URL>()
        let picks = urls.filter { seen.insert($0).inserted }.prefix(4)
        guard !picks.isEmpty else { return nil }

        // Fetched before any Core Graphics object exists, so nothing that isn't
        // `Sendable` ever crosses an await.
        var sources: [Data] = []
        for url in picks {
            if let data = await fetch(url) { sources.append(data) }
        }
        return render(sources, side: side, band: band)
    }

    /// The same composition from covers you already hold.
    ///
    /// A library playlist's songs carry their artwork in the row, so there is
    /// nothing to download — `LibraryService.coverData(for:)` uses this to give
    /// a coverless playlist the 2×2 a mix wears, out of its own first songs.
    static func compose(tiles: [Data], side: Int = 640) -> Data? {
        render(Array(tiles.prefix(4)), side: side)
    }

    private static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              !data.isEmpty
        else { return nil }
        return data
    }

    /// Four images make a 2×2; anything less is a single full-bleed tile.
    ///
    /// The same rule the card itself uses, so a saved mix and the mix it came
    /// from don't disagree about what they look like.
    private static func render(_ sources: [Data], side: Int, band: Band? = nil) -> Data? {
        guard !sources.isEmpty else { return nil }

        let tiles = sources.compactMap { decode($0, maxPixel: side) }
        guard !tiles.isEmpty else { return nil }

        guard let context = CGContext(
            data: nil,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(gray: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        if tiles.count >= 4 {
            let half = CGFloat(side) / 2
            let quadrants = [
                CGRect(x: 0,    y: half, width: half, height: half),   // top-left
                CGRect(x: half, y: half, width: half, height: half),   // top-right
                CGRect(x: 0,    y: 0,    width: half, height: half),   // bottom-left
                CGRect(x: half, y: 0,    width: half, height: half)    // bottom-right
            ]
            for (image, frame) in zip(tiles.prefix(4), quadrants) {
                draw(image, filling: frame, in: context)
            }
        } else {
            draw(tiles[0],
                 filling: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)),
                 in: context)
        }

        if let band { draw(band, side: side, in: context) }

        guard let composed = context.makeImage() else { return nil }
        return encode(composed)
    }

    /// The same band the card draws: a bottom-up ramp into the mix's colour,
    /// with the title sitting on it. Proportions mirror `MixCoverBand`.
    private static func draw(_ band: Band, side: Int, in context: CGContext) {
        let side   = CGFloat(side)
        let height = side * 0.42
        let colours = [
            CGColor(red: band.red, green: band.green, blue: band.blue, alpha: 0),
            CGColor(red: band.red, green: band.green, blue: band.blue, alpha: 0.92),
            CGColor(red: band.red, green: band.green, blue: band.blue, alpha: 1)
        ] as CFArray

        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours,
                                     locations: [0, 0.55, 1]) {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: side, height: height))
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: height),
                                       end:   CGPoint(x: 0, y: 0),
                                       options: [])
            context.restoreGState()
        }

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, side * 0.105, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let attributed = CFAttributedStringCreate(nil, band.title as CFString,
                                                  attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: side * 0.06, y: side * 0.055)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: side, height: height))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Aspect-fill: cover the frame and let the overflow be clipped, rather than
    /// squashing a square cover into a rectangle.
    private static func draw(_ image: CGImage, filling frame: CGRect, in context: CGContext) {
        let width  = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }

        let scale  = max(frame.width / width, frame.height / height)
        let drawn  = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: frame.midX - drawn.width / 2,
                             y: frame.midY - drawn.height / 2)

        context.saveGState()
        context.clip(to: frame)
        context.draw(image, in: CGRect(origin: origin, size: drawn))
        context.restoreGState()
    }

    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
