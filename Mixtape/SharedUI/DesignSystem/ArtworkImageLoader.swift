// Covers resolved and decoded off the main thread. A view gets the cached
// picture if there is one; otherwise it draws a placeholder and the picture
// arrives later. `AsyncArtworkImage` loads in `.task(id:)` after a short settle
// delay, so rows flung past are cancelled before doing any work.

import SwiftUI
import Combine

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What a view wants drawn. No `Data` case: callers with bytes use `mixImage(from:)`.
enum ArtworkSource: Hashable, Sendable {
    /// A track, album, artist or playlist row in the store.
    case row(ArtworkRef)
    /// A playlist's cover: its own, else the first song's, else a 2x2 of four
    /// different covers.
    case playlist(UUID)
}

/// Decoded covers keyed by row and size. Separate from `ArtworkDecodeCache`
/// (keyed by bytes), since a view here only has an id.
@MainActor
final class ArtworkImageLoader: ObservableObject {

    static let shared = ArtworkImageLoader()

    private let cache = NSCache<NSString, PlatformImage>()

    /// Candidate refs for a playlist's cover, best first. Supplied by
    /// `AppDependencies`; the rule lives in `LibraryService`.
    var playlistCoverRefs: ((UUID) -> [ArtworkRef])?

    private init() {
        // Charged by decoded size. 48MB is roughly 700 row covers.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    // MARK: - Reading

    /// Decoded picture or nil. No I/O or decoding, safe from `body`.
    func cached(_ source: ArtworkSource, bucket: Int) -> PlatformImage? {
        cache.object(forKey: Self.key(source, bucket))
    }

    /// Fetches and decodes if needed. Bytes are read on the main actor (the
    /// `ModelContext`); decoding runs in the background.
    func image(for source: ArtworkSource, bucket: Int) async -> PlatformImage? {
        if let hit = cached(source, bucket: bucket) { return hit }
        guard let resolved = resolveBytes(source) else { return nil }
        guard !Task.isCancelled else { return nil }

        // The 2x2 is composed off the main actor; only reading tiles needs it.
        let decoded = await Task.detached(priority: .utility) {
            guard let data = resolved.data(), !data.isEmpty else { return nil as PlatformImage? }
            return ArtworkDecodeCache.shared.decodedImage(for: data, bucket: bucket)
        }.value

        guard let decoded, !Task.isCancelled else { return nil }
        cache.setObject(decoded, forKey: Self.key(source, bucket), cost: Self.cost(decoded))
        return decoded
    }

    // MARK: - Invalidation

    /// Bumped when anything is forgotten. `AsyncArtworkImage` re-resolves only when
    /// its source changes, and a playlist's source (its id) doesn't change when the
    /// cover does, so this counter re-runs them. One counter for all refs:
    /// invalidations are rare and a per-ref map would have to be published too.
    @Published private(set) var generation = 0

    /// Drops everything (wipe, account switch, refresh), alongside `ArtworkProvider`.
    func invalidateAll() {
        cache.removeAllObjects()
        generation &+= 1
    }

    /// Forgets one row at every decode size, so the next draw re-reads it.
    func invalidate(_ ref: ArtworkRef) {
        invalidate([ref])
    }

    /// Forgets a batch of rows with one bump. Bumping per ref restarted every
    /// visible cover's load each time.
    func invalidate(_ refs: some Sequence<ArtworkRef>) {
        var emptied = false
        for ref in refs {
            emptied = true
            for bucket in ArtworkDecodeCache.buckets + [ArtworkDecodeCache.fullSize] {
                cache.removeObject(forKey: Self.key(.row(ref), bucket))
                if case .playlist(let id) = ref {
                    cache.removeObject(forKey: Self.key(.playlist(id), bucket))
                }
            }
        }
        if emptied { generation &+= 1 }
    }

    // MARK: - Private

    private static func key(_ source: ArtworkSource, _ bucket: Int) -> NSString {
        switch source {
        case .row(let ref):    return "\(Self.prefix(ref))\(ref.id.uuidString)|\(bucket)" as NSString
        case .playlist(let id): return "mosaic:\(id.uuidString)|\(bucket)" as NSString
        }
    }

    private static func prefix(_ ref: ArtworkRef) -> String {
        switch ref {
        case .track:    return "t:"
        case .album:    return "b:"
        case .artist:   return "r:"
        case .playlist: return "p:"
        }
    }

    /// Bytes, or tiles still to compose, so drawing can happen off the main actor.
    nonisolated private enum ResolvedArtwork {
        case ready(Data)
        case mosaic(tiles: [Data], fallback: Data)

        func data() -> Data? {
            switch self {
            case .ready(let data): return data
            case .mosaic(let tiles, let fallback):
                // 512, not 640 like a baked mix: not stored, and shown at most at 200pt.
                return MixCoverArt.compose(tiles: tiles, side: 512) ?? fallback
            }
        }
    }

    private func resolveBytes(_ source: ArtworkSource) -> ResolvedArtwork? {
        switch source {
        case .row(let ref):
            return ArtworkProvider.shared.data(for: ref).map(ResolvedArtwork.ready)

        case .playlist(let id):
            // A cover the user chose always wins, same as everywhere else.
            if let own = ArtworkProvider.shared.data(for: .playlist(id)) {
                return .ready(own)
            }

            // Four different covers, not the first four songs (one album would repeat).
            var tiles: [Data] = []
            var seen = Set<Fingerprint>()
            for ref in playlistCoverRefs?(id) ?? [] {
                guard let art = ArtworkProvider.shared.data(for: ref),
                      seen.insert(Fingerprint(art)).inserted else { continue }
                tiles.append(art)
                if tiles.count == 4 { break }
            }

            guard let first = tiles.first else { return nil }
            guard tiles.count >= 4 else { return .ready(first) }
            return .mosaic(tiles: tiles, fallback: first)
        }
    }

    /// Enough of a cover to tell it apart without hashing the whole image.
    private struct Fingerprint: Hashable {
        let count: Int
        let head:  Int
        let tail:  Int

        init(_ data: Data) {
            count = data.count
            head  = data.prefix(64).hashValue
            tail  = data.suffix(64).hashValue
        }
    }

    private static func cost(_ image: PlatformImage) -> Int {
        #if os(iOS)
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        #else
        let pixels = image.size.width * image.size.height
        #endif
        return max(1, Int(pixels) * 4)
    }
}

// MARK: - The view

/// Draws its placeholder immediately and fades the picture in, unless it's
/// already decoded. `size` is both the frame and the decode size.
struct AsyncArtworkImage<Placeholder: View>: View {

    let source: ArtworkSource?
    let size: CGFloat?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: PlatformImage?
    /// Not read directly; re-runs `.task` when a cover changes under the same
    /// source. See `ArtworkImageLoader.generation`.
    @ObservedObject private var loader = ArtworkImageLoader.shared

    /// How long a row must stay on screen before loading, so fast scrolling is free.
    private static var settleDelay: Duration { .milliseconds(60) }

    init(source: ArtworkSource?,
                size: CGFloat?,
                @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.source = source
        self.size = size
        self.placeholder = placeholder
    }

    private var bucket: Int { ArtworkDecodeCache.bucket(forPointSize: size) }

    /// Checked here too: `.task` runs after first render, so cached covers
    /// would otherwise flash the placeholder on every rebuild.
    private var image: PlatformImage? {
        if let loaded { return loaded }
        guard let source else { return nil }
        return ArtworkImageLoader.shared.cached(source, bucket: bucket)
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: ArtworkTaskID(source: source, generation: loader.generation)) {
            await load()
        }
    }

    private func load() async {
        guard let source else {
            loaded = nil
            return
        }
        if let hit = ArtworkImageLoader.shared.cached(source, bucket: bucket) {
            loaded = hit
            return
        }
        // Not cleared: this reruns whenever any cover changes, and clearing blanked
        // every row. Keeping the old picture risks at most one stale frame.

        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }

        let image = await ArtworkImageLoader.shared.image(for: source, bucket: bucket)
        guard !Task.isCancelled, let image else { return }
        withAnimation(.easeIn(duration: 0.18)) { loaded = image }
    }
}


/// Reruns the load: the source plus the cache generation.
private struct ArtworkTaskID: Equatable {
    let source: ArtworkSource?
    let generation: Int
}
