// ArtworkImageLoader.swift
// Mixtape — SharedUI/DesignSystem
//
// Covers, resolved and decoded off the render path.
//
// A row used to draw its cover entirely inside `body`: a keyed fetch against
// the store for the bytes, then an ImageIO decode of an ~84 KB JPEG, then the
// picture. Both halves ran on the main thread, synchronously, once per row per
// evaluation — and a list of 2 200 songs re-evaluates dozens of rows per frame
// while it scrolls. That is the stutter.
//
// So the drawing and the fetching come apart. A view asks this for a cover and
// gets one of two answers: the decoded picture, if it has been drawn before and
// is still cached, or nothing — in which case the view draws its placeholder
// now and the picture arrives a moment later, decoded on a background thread.
//
// The part that actually saves the scroll is cancellation. `AsyncArtworkImage`
// loads inside a `.task(id:)`, which SwiftUI cancels when the row scrolls away
// or is recycled, and the load waits out a short settle delay before it touches
// anything. Fling past four hundred rows and four hundred loads are started and
// cancelled before doing a byte of work; only what you stop on is paid for.

import SwiftUI
import Combine

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What a view wants drawn.
///
/// Deliberately not a case carrying `Data`: a caller that already holds the
/// bytes has nothing to wait for and goes straight through `mixImage(from:)`.
/// Everything here is an identity that has to be resolved before it can be
/// drawn, which is exactly the work worth deferring.
enum ArtworkSource: Hashable, Sendable {
    /// A track, album, artist or playlist row in the store.
    case row(ArtworkRef)
    /// A playlist's cover including the one it borrows from its songs — its
    /// own picture if it has one, the first song's if it doesn't, or the 2×2
    /// once there are four different ones to show.
    case playlist(UUID)
}

/// Decoded covers, keyed by row and decode size.
///
/// Separate from `ArtworkDecodeCache`, which is keyed by the bytes: a view
/// working from an `ArtworkSource` doesn't have the bytes, and going and
/// getting them just to look up a cache would be most of the cost it is trying
/// to avoid. This one answers from a UUID.
@MainActor
final class ArtworkImageLoader: ObservableObject {

    static let shared = ArtworkImageLoader()

    private let cache = NSCache<NSString, PlatformImage>()

    /// Refs to borrow a playlist's cover from, in order, best first. Supplied
    /// by `AppDependencies` because the rule lives in `LibraryService` — which
    /// this layer has no business importing.
    var playlistCoverRefs: ((UUID) -> [ArtworkRef])?

    private init() {
        // Decoded bitmaps, charged at their real pixel cost. A 48pt row cover
        // is a 128×128 bitmap at 64 KB, so this holds something like seven
        // hundred rows' worth — plenty for any scrollback a person does, and
        // bounded for the library that is twenty times that long.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    // MARK: - Reading

    /// The picture if it is already decoded, nil if it isn't. Cheap enough to
    /// call from `body`; does no I/O and no decoding.
    func cached(_ source: ArtworkSource, bucket: Int) -> PlatformImage? {
        cache.object(forKey: Self.key(source, bucket))
    }

    /// The picture, fetching and decoding it if need be.
    ///
    /// Resolving the bytes happens on the main actor because that is where the
    /// `ModelContext` lives; the decode — the expensive half — is handed to a
    /// background task. Cancellation is honoured between the two.
    func image(for source: ArtworkSource, bucket: Int) async -> PlatformImage? {
        if let hit = cached(source, bucket: bucket) { return hit }
        guard let resolved = resolveBytes(source) else { return nil }
        guard !Task.isCancelled else { return nil }

        // Composing the 2×2 belongs on this side of the hop, not in
        // `resolveBytes`. Only reading the tiles needs the main actor — the
        // `ModelContext` lives there — and drawing a 512px mosaic while a
        // playlist page is trying to appear is what made opening one hang.
        let decoded = await Task.detached(priority: .utility) {
            guard let data = resolved.data(), !data.isEmpty else { return nil as PlatformImage? }
            return ArtworkDecodeCache.shared.decodedImage(for: data, bucket: bucket)
        }.value

        guard let decoded, !Task.isCancelled else { return nil }
        cache.setObject(decoded, forKey: Self.key(source, bucket), cost: Self.cost(decoded))
        return decoded
    }

    // MARK: - Invalidation

    /// Bumped whenever anything is forgotten.
    ///
    /// Emptying the caches is not enough to change what is on screen. Every
    /// `AsyncArtworkImage` holds its picture in `@State` and re-resolves only
    /// when its `source` changes — and the source of a playlist cover is the
    /// playlist's id, which is exactly what does *not* change when the user
    /// picks a new cover for it. So the rows kept drawing the old image until
    /// something destroyed the view tree, which is why a new cover appeared
    /// only after a full refresh or a relaunch.
    ///
    /// One counter for all refs rather than one per ref: an invalidation is
    /// rare, and the views that react re-read a warm cache. A per-ref map would
    /// have to be published too, and publishing a dictionary to every artwork
    /// view in the tree costs more than the re-reads it saves.
    @Published private(set) var generation = 0

    /// Drops everything. A wipe, an account switch, or a library refresh — the
    /// same moment `ArtworkProvider` forgets its bytes.
    func invalidateAll() {
        cache.removeAllObjects()
        generation &+= 1
    }

    /// Forgets one row at every decode size, so the next draw re-reads it.
    func invalidate(_ ref: ArtworkRef) {
        invalidate([ref])
    }

    /// Forgets a batch of rows for the price of one redraw.
    ///
    /// The bump is what makes every `AsyncArtworkImage` on screen re-resolve, so
    /// doing it once per ref is not a small waste — saving a 24-song mix bumped
    /// it two dozen times in a row, and each bump cancelled and restarted the
    /// load task of every cover in the window. The covers blanked and the app
    /// dropped frames for seconds, which is worse than the blanket
    /// `invalidateAll` this was meant to improve on. Empty every key first,
    /// then announce once.
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

    /// Bytes in hand, or the tiles a mosaic still has to be drawn from.
    ///
    /// The distinction exists so the drawing can happen off the main actor —
    /// see `image(for:bucket:)`.
    private enum ResolvedArtwork {
        case ready(Data)
        case mosaic(tiles: [Data], fallback: Data)

        func data() -> Data? {
            switch self {
            case .ready(let data): return data
            case .mosaic(let tiles, let fallback):
                // 512 rather than the 640 a saved mix is baked at: nothing here
                // is stored and the largest thing that shows it is a 200pt hero.
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

            // Four *different* pictures, not the first four songs: a playlist
            // that is one album would otherwise get a 2×2 of the same cover
            // four times. The candidate list is longer than four for exactly
            // this reason.
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

    /// Enough of a cover to tell it apart from another one without hashing the
    /// whole image.
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

/// A cover that draws its placeholder immediately and fades the picture in when
/// it arrives — unless the picture is already decoded, in which case it is
/// there on the first frame and nothing fades.
///
/// `size` is both the frame and the decode size: a 48pt row gets a 128×128
/// bitmap rather than the full 512×512 blob.
struct AsyncArtworkImage<Placeholder: View>: View {

    let source: ArtworkSource?
    let size: CGFloat?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: PlatformImage?
    /// Not read directly — it is what re-runs `.task` when a cover is replaced
    /// under a source that hasn't changed. See `ArtworkImageLoader.generation`.
    @ObservedObject private var loader = ArtworkImageLoader.shared

    /// How long a row has to stay on screen before its cover is worth fetching.
    ///
    /// This is the whole fast-scroll fix. A fling recycles a row long before
    /// this elapses, SwiftUI cancels its `.task`, and the row costs nothing at
    /// all. Long enough to skip everything flying past, short enough that
    /// stopping anywhere fills in within a frame or two of settling.
    private static var settleDelay: Duration { .milliseconds(60) }

    init(source: ArtworkSource?,
                size: CGFloat?,
                @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.source = source
        self.size = size
        self.placeholder = placeholder
    }

    private var bucket: Int { ArtworkDecodeCache.bucket(forPointSize: size) }

    /// The cache is consulted here rather than only in `.task` on purpose:
    /// `.task` runs after the first render, so a cover already in hand would
    /// otherwise flash its placeholder for a frame every time the row was
    /// rebuilt — which, in a list, is constantly.
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
        // Deliberately *not* cleared here.
        //
        // This runs again whenever `generation` moves, which is any time any
        // cover in the library is rewritten — and dropping the picture first
        // meant every row on screen fell back to its placeholder for at least
        // `settleDelay`, then decoded its way back to the same image. One song
        // gaining a cover blanked the entire window. Holding the old picture
        // until a new one arrives is correct even when the bytes really did
        // change: the worst case is one frame of a stale cover, against a
        // guaranteed flash of no cover at all.
        //
        // A source that genuinely has nothing is still handled — `image`
        // resolves through the cache when `loaded` is nil, and a row that never
        // had a picture has nothing to hold.

        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }

        let image = await ArtworkImageLoader.shared.image(for: source, bucket: bucket)
        guard !Task.isCancelled, let image else { return }
        withAnimation(.easeIn(duration: 0.18)) { loaded = image }
    }
}


/// What re-runs `AsyncArtworkImage`'s load: the thing being drawn, and the
/// number of times the caches have been emptied since.
private struct ArtworkTaskID: Equatable {
    let source: ArtworkSource?
    let generation: Int
}
