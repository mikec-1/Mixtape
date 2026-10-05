// ImageIO downsampling for iOS and macOS.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// `nonisolated`: pure ImageIO, and bulk artwork callers run off main.
public nonisolated enum ImageDownsampler {

    /// Downsamples so the longest edge is at most `maxDimension`, then re-encodes
    /// as JPEG. Decodes straight to the target size. Nil if the data isn't an image.
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

    /// Max edge for stored covers, sharp on a Retina detail hero.
    static let artworkMaxDimension: CGFloat = 1024

    /// Blobs this small are stored as-is; re-encoding only loses quality.
    static let artworkPassthroughBytes = 256 * 1024

    /// Longest edge of an encoded image, read from the header without decoding.
    /// Used to find covers stored at the old 300/512 px limits.
    static func longestEdge(of data: Data) -> CGFloat? {
        pixelSize(of: data).map { max($0.width, $0.height) }
    }

    /// Pixel size from the header, without decoding.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Shrinks artwork on its way into the library. Every `artworkData` write goes
    /// through here. Returns the input when already small or not decodable.
    static func artworkJPEG(from data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count > artworkPassthroughBytes else { return data }
        return downsampledJPEG(from: data,
                               maxDimension: artworkMaxDimension,
                               compressionQuality: 0.8) ?? data
    }
}
