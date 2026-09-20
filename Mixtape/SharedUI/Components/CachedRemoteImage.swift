// CachedRemoteImage.swift
// Mixtape — SharedUI/Components
//
// A remote image that remembers what it already fetched.
//
// SwiftUI's `AsyncImage` ties its download to *view identity*: leave Discover
// and come back, scroll a row out and back, push an artist page and pop it —
// each time the view is rebuilt, the load starts over from the placeholder.
// URLSession's HTTP cache sometimes spares the network, but never the decode,
// and the placeholder flash is visible either way. Discover is a wall of remote
// covers, so every navigation repainted the whole grid grey and filled it back
// in one image at a time.
//
// This keeps decoded images in memory for the life of the process and hands
// back a cache hit synchronously, so a revisit draws the artwork in its first
// frame with no flash at all.

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

/// Process-wide store of decoded remote artwork.
///
/// `NSCache` is thread-safe on its own and evicts under memory pressure, which
/// is the whole reason it's here rather than a dictionary. The in-flight table
/// beside it is not, hence the lock — and it is what stops a grid of twenty
/// cards that all show the same artist from opening twenty identical downloads.
final class RemoteImageCache: @unchecked Sendable {

    static let shared = RemoteImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        // Cost is the *downloaded* byte count, not the decoded bitmap: it's the
        // number we actually have, and it tracks the real one closely enough to
        // keep the cache bounded. Covers run tens of KB, so this holds a very
        // long browsing session without being a memory problem.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Drop every cached picture. Called on memory pressure — the bytes are all
    /// re-downloadable, so this is the cheapest large thing the app can give
    /// back before the system starts killing it.
    func purge() {
        cache.removeAllObjects()
    }

    /// A hit, or nil. Synchronous and safe to call during `View.init`, which is
    /// what lets a cached image skip the placeholder entirely.
    func cached(_ url: URL?) -> PlatformImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        lock.lock()
        if let running = inFlight[url] {
            lock.unlock()
            return await running.value
        }
        let task = Task<PlatformImage?, Never> { [cache] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let image = PlatformImage(data: data)
            else { return nil }
            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        }
        inFlight[url] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inFlight[url] = nil
        lock.unlock()
        return image
    }
}

/// Drop-in replacement for the `AsyncImage(url:content:placeholder:)` shape.
///
/// Same call sites, same two builders — the difference is that a URL fetched
/// once stays fetched.
struct CachedRemoteImage<Content: View, Placeholder: View>: View {

    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    /// Seeded from the cache so a hit renders on the first frame. Waiting for
    /// `.task` would put a placeholder on screen for a frame first, which is the
    /// flash this type exists to remove.
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
            // Re-check: the identity change that restarted this task may have
            // arrived after init, pointing at a URL already in the cache.
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
