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

    private let cache = NSCache<NSURL, PlatformImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        // Cost is downloaded bytes, close enough to keep it bounded.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Called on memory pressure; everything here is re-downloadable.
    func purge() {
        cache.removeAllObjects()
    }

    /// Synchronous and safe in `View.init`, so a hit skips the placeholder.
    func cached(_ url: URL?) -> PlatformImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        let (task, isNew) = lock.withLock { () -> (Task<PlatformImage?, Never>, Bool) in
            if let running = inFlight[url] { return (running, false) }
            let task = Task<PlatformImage?, Never> { [cache] in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                      let image = PlatformImage(data: data)
                else { return nil }
                cache.setObject(image, forKey: url as NSURL, cost: data.count)
                return image
            }
            inFlight[url] = task
            return (task, true)
        }

        let image = await task.value
        if isNew { lock.withLock { inFlight[url] = nil } }
        return image
    }
}

/// Drop-in for `AsyncImage(url:content:placeholder:)`.
struct CachedRemoteImage<Content: View, Placeholder: View>: View {

    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    /// Seeded from the cache so a hit renders on the first frame.
    @State private var image: PlatformImage?

    init(url: URL?,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: RemoteImageCache.shared.cached(url))
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
            if let hit = RemoteImageCache.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            let loaded = await RemoteImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
