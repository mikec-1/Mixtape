// Artwork `Data` to a SwiftUI `Image`, UIImage or NSImage underneath.

import SwiftUI
import ImageIO

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Decoded artwork cache, so rows don't re-decode on every body evaluation.
/// Keyed on `NSData`: `NSCache` compares with `isEqual:`, so a collision costs a
/// memcmp, never a wrong cover.
nonisolated final class ArtworkDecodeCache: @unchecked Sendable {

    static let shared = ArtworkDecodeCache()

    /// One cache per decode size, since the same bytes decode to several sizes.
    private var caches: [Int: NSCache<NSData, PlatformImage>] = [:]
    private let lock = NSLock()

    /// Decode sizes in pixels; thumbnails share the smallest bucket that covers them.
    /// `fullSize` decodes as stored (artwork is already downsampled to 512 on write,
    /// see `ImageDownsampler.artworkMaxDimension`).
    static let buckets = [64, 128, 256, 512]
    static let fullSize = 0

    /// Assumed backing scale: the platform max, so thumbnails are never too small.
    #if os(iOS)
    static let assumedScale: CGFloat = 3
    #else
    static let assumedScale: CGFloat = 2
    #endif

    /// Bucket for something `points` wide, or `fullSize` if big enough.
    static func bucket(forPointSize points: CGFloat?) -> Int {
        guard let points, points > 0 else { return fullSize }
        let pixels = points * assumedScale
        return buckets.first { CGFloat($0) >= pixels } ?? fullSize
    }

    /// Drops every decode. Called on memory pressure.
    func purge() {
        lock.lock()
        defer { lock.unlock() }
        for cache in caches.values { cache.removeAllObjects() }
    }

    private func cache(for bucket: Int) -> NSCache<NSData, PlatformImage> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = caches[bucket] { return existing }
        let created = NSCache<NSData, PlatformImage>()
        // Charged in decoded bytes, not encoded.
        created.totalCostLimit = 64 * 1024 * 1024
        caches[bucket] = created
        return created
    }

    func image(for data: Data, bucket: Int) -> PlatformImage? {
        let store = cache(for: bucket)
        let key = data as NSData
        if let hit = store.object(forKey: key) { return hit }
        guard let decoded = Self.decode(data, bucket: bucket) else { return nil }
        store.setObject(decoded, forKey: key, cost: Self.decodedCost(decoded))
        return decoded
    }

    /// Cached picture or nil, never a decode. Safe from `body`.
    func cachedImage(for data: Data, bucket: Int) -> PlatformImage? {
        cache(for: bucket).object(forKey: data as NSData)
    }

    /// Decodes and caches on the caller's thread. `decode` is pure ImageIO and
    /// the cache is lock-guarded, hence `@unchecked Sendable`.
    nonisolated func decodedImage(for data: Data, bucket: Int) -> PlatformImage? {
        image(for: data, bucket: bucket)
    }

    static func decode(_ data: Data, bucket: Int) -> PlatformImage? {
        guard bucket != fullSize else { return PlatformImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if os(iOS)
        return UIImage(cgImage: thumb)
        #else
        return NSImage(cgImage: thumb, size: .zero)
        #endif
    }

    private static func decodedCost(_ image: PlatformImage) -> Int {
        #if os(iOS)
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        #else
        let pixels = image.size.width * image.size.height
        #endif
        return max(1, Int(pixels) * 4)
    }
}

/// A SwiftUI `Image` from image `Data`, or nil if undecodable.
/// - Parameter displaySize: draw width in points, if known. Decodes a thumbnail
/// near that size instead of the whole blob. Nil for large artwork.
public func mixImage(from data: Data, displaySize: CGFloat? = nil) -> Image? {
    let bucket = ArtworkDecodeCache.bucket(forPointSize: displaySize)
    guard let platform = ArtworkDecodeCache.shared.image(for: data, bucket: bucket) else { return nil }
    return Image(platformImage: platform)
}
