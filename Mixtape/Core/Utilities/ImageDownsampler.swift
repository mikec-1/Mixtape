// ImageDownsampler.swift
// Mixtape
//
// ImageIO downsampling (iOS + macOS). Shrinks a picked photo before avatar upload
// so we don't push a multi-megabyte original into Storage.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageDownsampler {

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
