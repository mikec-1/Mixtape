// Remote image with an in-memory cache. `AsyncImage` reloads on every view
// rebuild, so Discover flashed grey on every revisit. Cache hits draw on the first frame.

import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Process-wide decoded artwork. NSCache is thread-safe and evicts under pressure;
/// the lock guards the in-flight table, which dedupes identical downloads.
final class RemoteImageCache: @unchecked Sendable {

    static let shared = RemoteImageCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let lock = NSLock()
    /// Deezer's biggest covers. Share cards and anything without a known size decode at this.
    nonisolated static let maxPixels = 1000
    private var inFlight: [NSString: Task<PlatformImage?, Never>] = [:]

    private init() {
        // Charged in decoded bytes. Download size undercounted a 1000px cover about 25 times, so the cap
        // held over a gigabyte.
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    /// Decode size for something `points` wide. A 1000px cover is 4 MB decoded and Core Animation keeps
    /// a second copy, so a Discover page of cards held over a gigabyte.
    nonisolated static func pixels(forPoints points: CGFloat?) -> Int {
        guard let points, points > 0 else { return 512 }
        let needed = Int((points * ArtworkDecodeCache.assumedScale).rounded(.up))
        return [128, 256, 512].first { $0 >= needed } ?? maxPixels
    }

    /// Called on memory pressure; everything here is re-downloadable.
    func purge() {
        cache.removeAllObjects()
    }

    private nonisolated static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(pixels)|\(url.absoluteString)" as NSString
    }

    /// Synchronous and safe in `View.init`, so a hit skips the placeholder.
    func cached(_ url: URL?, pixels: Int = RemoteImageCache.maxPixels) -> PlatformImage? {
        guard let url else { return nil }
        return cache.object(forKey: Self.key(url, pixels))
            ?? (pixels < Self.maxPixels ? cache.object(forKey: Self.key(url, Self.maxPixels)) : nil)
    }

    func image(for url: URL, pixels: Int = RemoteImageCache.maxPixels) async -> PlatformImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        let key = Self.key(url, pixels)

        let (task, isNew) = lock.withLock { () -> (Task<PlatformImage?, Never>, Bool) in
            if let running = inFlight[key] { return (running, false) }
            // Detached so the decode stays off the main thread.
            let task = Task.detached(priority: .userInitiated) { [cache] () -> PlatformImage? in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                      let image = ArtworkDecodeCache.decode(data, bucket: pixels)
                else { return nil }
                cache.setObject(image, forKey: key, cost: ArtworkDecodeCache.decodedCost(image))
                return image
            }
            inFlight[key] = task
            return (task, true)
        }

        let image = await task.value
        if isNew { lock.withLock { inFlight[key] = nil } }
        return image
    }
}

/// Drop-in for `AsyncImage(url:content:placeholder:)`.
struct CachedRemoteImage<Content: View, Placeholder: View>: View {

    private let url: URL?
    private let pixels: Int
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    /// Seeded from the cache so a hit renders on the first frame.
    @State private var image: PlatformImage?

    /// `points`: the drawn width, so a 44pt row doesn't decode a 1000px cover.
    init(url: URL?, points: CGFloat? = nil,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.pixels = RemoteImageCache.pixels(forPoints: points)
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: RemoteImageCache.shared.cached(url, pixels: pixels))
    }

    var body: some View {
        Group {
            if let image {
                content(Image(platformImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            // The URL may have changed to a cached one after init.
            if let hit = RemoteImageCache.shared.cached(url, pixels: pixels) {
                image = hit
                return
            }
            image = nil
            let loaded = await RemoteImageCache.shared.image(for: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
