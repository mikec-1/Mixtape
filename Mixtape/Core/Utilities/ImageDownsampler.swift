// ImageDownsampler.swift
// Mixtape
//
// ImageIO downsampling (iOS + macOS). Shrinks a picked photo before avatar upload
// so we don't push a multi-megabyte original into Storage.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// `nonisolated` on purpose. The project defaults to `MainActor` isolation, and
/// this is pure ImageIO over bytes with no state to protect — the callers that
/// matter most (bulk artwork downloads, the cover backfill) run off the main
/// actor precisely so the decoding doesn't block the UI.
public nonisolated enum ImageDownsampler {

    /// Downsamples `data` so its longest edge is at most `maxDimension` points,
    /// then re-encodes as JPEG at `compressionQuality`. Returns nil if the data
    /// isn't a decodable image.
    ///
    /// Uses `CGImageSourceCreateThumbnailAtIndex`, which decodes straight to the
    /// target size without materializing the full-resolution bitmap — cheap even
    /// for large originals.
    public static func downsampledJPEG(
        from data: Data,
        maxDimension: CGFloat = 512,
        compressionQuality: CGFloat = 0.82
    ) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respect EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return nil
        }

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destOptions = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        CGImageDestinationAddImage(dest, thumbnail, destOptions)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return outData as Data
    }
}

// MARK: - Library Artwork

public nonisolated extension ImageDownsampler {

    /// The longest edge any cover stored on a Track, Album or Artist row is
    /// allowed to have. Big enough for the detail hero on a Retina display,
    /// small enough to stay a JPEG and not a photograph. It was 512, which was
    /// visibly soft on a Retina hero; bulk fetches no longer load blobs at all
    /// (`ArtworkProvider`'s `propertiesToFetch`), so the old memory argument for
    /// keeping it tiny no longer applies.
    static let artworkMaxDimension: CGFloat = 1024

    /// Blobs at or under this size are stored as they arrived. Re-encoding a
    /// cover that is already small buys nothing and costs a generation of JPEG
    /// quality.
    static let artworkPassthroughBytes = 256 * 1024

    /// Shrinks artwork on its way into the library.
    ///
    /// Every path that writes `artworkData` goes through here. Embedded covers
    /// pulled out of an MP3 are routinely 1–3 MB each, and catalogue downloads
    /// arrive at whatever size the URL asked for; stored raw, a few thousand
    /// songs' worth is gigabytes of resident memory the app can never give back.
    ///
    /// Returns the original bytes when they're already small enough, and when
    /// the data isn't a decodable image — a caller storing something we can't
    /// read is no worse off than before.
    /// The longest edge of an encoded image, without decoding it.
    ///
    /// ImageIO reads this out of the header, so it is cheap enough to ask of
    /// every cover in a library — which is what the cover-quality re-fetch does
    /// to find the ones stored back when the ceiling was 300 or 512 px.
    static func longestEdge(of data: Data) -> CGFloat? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return max(w, h)
    }

    static func artworkJPEG(from data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count > artworkPassthroughBytes else { return data }
        return downsampledJPEG(from: data,
                               maxDimension: artworkMaxDimension,
                               compressionQuality: 0.8) ?? data
    }
}
