// PlatformImage.swift
// Mixtape — Design System
//
// One way to turn raw artwork `Data` into a SwiftUI `Image`. Every artwork view
// needs this and the platform image type differs, so it lived as a private
// copy in eight views before landing here.
//
// Cross-platform: UIImage on iOS, NSImage elsewhere.

import SwiftUI
import ImageIO

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Decoded artwork, kept so a row doesn't decode its cover again every time
/// something on it changes.
///
/// This is called from inside `body`, which is the whole problem: a hover, a
/// selection, a track change or a scroll re-evaluates every visible row, and
/// each evaluation was decoding its cover's JPEG from scratch. The bytes never
/// change — the same `Data` always decodes to the same picture — so the decode
/// is pure waste from the second one onwards.
///
/// Keyed on `NSData` rather than a hash of the bytes on purpose. `NSCache`
/// compares keys with `isEqual:`, so a hash collision costs a memcmp and not a
/// wrong cover; a hand-rolled digest key would have to be either slow or
/// occasionally wrong, and "occasionally the wrong album art" is not a
/// trade worth making for a decode.
final class ArtworkDecodeCache: @unchecked Sendable {

    static let shared = ArtworkDecodeCache()

    /// One cache per decode size. `NSCache` keys are objects compared with
    /// `isEqual:`, and the key here is the bytes; the same blob legitimately
    /// decodes to several different pictures now, so the size has to be part of
    /// the identity. A dictionary of caches keeps that split without inventing
    /// a composite key class whose equality would be one more thing to get
    /// wrong.
    private var caches: [Int: NSCache<NSData, PlatformImage>] = [:]
    private let lock = NSLock()

    /// Decode sizes, in pixels. A thumbnail asks for the smallest bucket that
    /// covers it, so the dozens of slightly different thumbnail sizes in the
    /// app share a handful of decodes instead of one each.
    ///
    /// `fullSize` means "decode the blob as it is". It is the ceiling because
    /// stored artwork is downsampled to 512pt on write (see
    /// `ImageDownsampler.artworkMaxDimension`) — asking for more would just
    /// upscale.
    static let buckets = [64, 128, 256, 512]
    static let fullSize = 0

    /// Backing-scale assumed when converting a point size to a pixel size.
    ///
    /// A constant rather than a screen lookup: this is reached from `body` on
    /// every row and the only thing it can do wrong is over-decode slightly.
    /// Both values are the maximum for their platform, so a thumbnail is never
    /// decoded smaller than it is drawn.
    #if os(iOS)
    static let assumedScale: CGFloat = 3
    #else
    static let assumedScale: CGFloat = 2
    #endif

    /// The bucket to decode at for something drawn `points` wide, or
    /// `fullSize` when the drawing is big enough that the stored blob is
    /// already the right answer.
    static func bucket(forPointSize points: CGFloat?) -> Int {
        guard let points, points > 0 else { return fullSize }
        let pixels = points * assumedScale
        return buckets.first { CGFloat($0) >= pixels } ?? fullSize
    }

    /// Drop every decode at every size. Called on memory pressure; the blobs
    /// they came from are still on disk, so this costs a re-decode and nothing
    /// more.
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
        // Charged in *decoded* bytes, which is the number that matters and the
        // one the previous version got wrong: it billed the encoded size, so a
        // 48 MB budget of ~50 KB JPEGs meant roughly a thousand 512×512
        // bitmaps — the better part of a gigabyte — resident and considered
        // within budget.
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

    /// The decoded picture if it is already in hand, and nil rather than a
    /// decode if it isn't. What a view calls from `body`, so drawing a cover
    /// that has been drawn before still costs nothing and doesn't flash.
    func cachedImage(for data: Data, bucket: Int) -> PlatformImage? {
        cache(for: bucket).object(forKey: data as NSData)
    }

    /// Decodes and caches, off whatever thread the caller is on. `decode` is
    /// pure ImageIO and touches no shared state; the cache behind it is
    /// lock-guarded, which is what `@unchecked Sendable` is claiming here.
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

/// A SwiftUI `Image` decoded from raw image `Data`, or `nil` if the bytes
/// aren't decodable on this platform.
///
/// - Parameter displaySize: the width in points the image will be drawn at, if
///   known. Passing it decodes a thumbnail of about that size instead of the
///   whole blob — a 40pt row cover costs a 120×120 bitmap rather than a
///   512×512 one, roughly eighteen times less memory for a picture that is
///   never drawn larger. Pass `nil` for artwork shown large, where the stored
///   blob already is the right size.
public func mixImage(from data: Data, displaySize: CGFloat? = nil) -> Image? {
    let bucket = ArtworkDecodeCache.bucket(forPointSize: displaySize)
    guard let platform = ArtworkDecodeCache.shared.image(for: data, bucket: bucket) else { return nil }
    return Image(platformImage: platform)
}
