// ArtworkProvider.swift
// Mixtape — Core/Services
//
// Artwork on demand, for rows whose blob was deliberately left out of the bulk
// fetch.
//
// `LibraryService.refresh()` reads every track, album and artist in one pass.
// Those rows carry their cover inline — SwiftData only moves a blob to external
// storage above ~128 KB and a downsampled cover is around 80 KB — so the fetch
// was materialising ~167 MB of artwork for the tracks alone, on the main thread,
// to publish arrays that a screenful of rows draws twenty covers from.
//
// So the bulk fetches skip the blob (`propertiesToFetch`) and the domain struct
// comes back with `artworkData == nil`. The picture is then fetched one row at a
// time, when a view actually asks to draw it, and kept in a bounded cache.
//
// `Track.artworkData` is still a real stored property and still wins when it is
// set: an online track playing from Discover carries artwork that was never in
// the database, and the queue assigns it directly. This provider is only ever
// the fallback for rows that live in the store.

import Foundation
import SwiftData
import CoreGraphics

/// Which row a view wants the cover for.
public enum ArtworkRef: Hashable, Sendable {
    case track(UUID)
    case album(UUID)
    case artist(UUID)
    case playlist(UUID)

    var id: UUID {
        switch self {
        case .track(let id), .album(let id), .artist(let id), .playlist(let id): return id
        }
    }
}

@MainActor
public final class ArtworkProvider {

    public static let shared = ArtworkProvider()

    private let cache = NSCache<NSString, NSData>()

    /// The context every blob read goes through — and it is deliberately not the
    /// app's main context.
    ///
    /// Reading `artworkData` faults the blob into whichever context asked, and
    /// that context keeps the row registered for as long as it lives. Against
    /// the main context that meant every cover scrolled past stayed resident for
    /// the life of the process: a pass down a 2200-row playlist added ~170 MB
    /// that nothing could ever release.
    ///
    /// A scratch context is thrown away every `readsBeforeReset` reads, and the
    /// faulted blobs die with it. Read-only, never saved, so there is nothing to
    /// merge back and no risk of dropping a pending change.
    private var scratch: ModelContext?
    private var readsSinceReset = 0

    /// Small enough that the resident set stays bounded, large enough that a
    /// screenful of rows never pays for a context twice.
    private static let readsBeforeReset = 150

    private init() {
        // Encoded bytes, which is what this holds — the decoded-bitmap budget is
        // `ArtworkDecodeCache`'s problem and is accounted separately.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// A context to read blobs through, recycled periodically.
    ///
    /// Built from whichever account's store is open — never held across a
    /// switch, since every row id in the closed file is meaningless in the new
    /// one. `ModelStore.open` drops the scratch for exactly that reason.
    private func readContext() -> ModelContext? {
        if scratch == nil {
            scratch = ModelContext(ModelStore.shared.container)
            readsSinceReset = 0
        }
        return scratch
    }

    /// Drops the scratch context and everything it had faulted in.
    private func recycleIfNeeded() {
        readsSinceReset += 1
        guard readsSinceReset >= Self.readsBeforeReset else { return }
        scratch = nil
        readsSinceReset = 0
    }

    /// Drops everything. A wipe or an account switch invalidates every id.
    public func invalidateAll() {
        cache.removeAllObjects()
        scratch = nil
    }

    /// Forgets one row, so the next draw re-reads it. Used when artwork is
    /// written — a cover fetched by the backfill, or one the user picked.
    public func invalidate(_ ref: ArtworkRef) {
        invalidate([ref])
    }

    /// Forgets a batch of rows. One scratch reset for the lot rather than one
    /// each — the context is rebuilt on the next read either way.
    public func invalidate(_ refs: some Sequence<ArtworkRef>) {
        var emptied = false
        for ref in refs {
            emptied = true
            cache.removeObject(forKey: Self.key(ref))
        }
        // The scratch context predates the writes that prompted this, and would
        // hand back the stale rows it already has registered.
        if emptied { scratch = nil }
    }

    /// The cover for a row, or nil if it has none.
    ///
    /// Misses are deliberately not cached. A row with no artwork today routinely
    /// has one tomorrow — the artwork backfill and the sync download both fill
    /// them in behind the UI — and a cached nil would keep showing a placeholder
    /// over a picture that had already arrived.
    public func data(for ref: ArtworkRef) -> Data? {
        let key = Self.key(ref)
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let data = fetch(ref), !data.isEmpty else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        recycleIfNeeded()
        return data
    }

    /// Live track ids that do have a cover. The set a playlist borrows from,
    /// answered without reading a single blob — the store can evaluate the
    /// nil-check itself, and only `id` comes back.
    public func trackIDsWithArtwork() -> Set<UUID> {
        guard let context = readContext() else { return [] }
        var d = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkData != nil && !$0.isSoftDeleted }
        )
        d.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(d)) ?? []).map(\.id))
    }

    /// Live track ids with no cover stored, cheapest way to ask now that the
    /// bulk fetch no longer carries the blob. Only `id` is read back.
    public func trackIDsWithoutArtwork() -> [UUID] {
        guard let context = readContext() else { return [] }
        var d = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkData == nil && !$0.isSoftDeleted }
        )
        d.propertiesToFetch = [\.id]
        return ((try? context.fetch(d)) ?? []).map(\.id)
    }

    /// Live track ids whose stored cover is smaller than `maxDimension`.
    ///
    /// Rows written before the ceiling went up — 300 px for anything that
    /// arrived over sync, 512 px for anything written locally — look soft on a
    /// Retina hero and can only be fixed by fetching the cover again. Reads
    /// blobs in pages so the whole library is never resident at once, and only
    /// the header of each, never the pixels.
    public func trackIDsWithLowResArtwork(maxDimension: CGFloat) -> [UUID] {
        guard let context = readContext() else { return [] }
        var out: [UUID] = []
        var offset = 0
        while true {
            var d = FetchDescriptor<TrackEntity>(
                predicate: #Predicate { $0.artworkData != nil && !$0.isSoftDeleted },
                sortBy: [SortDescriptor(\.id)]
            )
            d.fetchLimit  = 200
            d.fetchOffset = offset
            guard let batch = try? context.fetch(d), !batch.isEmpty else { break }
            offset += batch.count
            for row in batch {
                guard let data = row.artworkData,
                      let edge = ImageDownsampler.longestEdge(of: data), edge < maxDimension
                else { continue }
                out.append(row.id)
            }
        }
        return out
    }

    private static func key(_ ref: ArtworkRef) -> NSString {
        switch ref {
        case .track(let id):    return "t:\(id.uuidString)" as NSString
        case .album(let id):    return "b:\(id.uuidString)" as NSString
        case .artist(let id):   return "r:\(id.uuidString)" as NSString
        case .playlist(let id): return "p:\(id.uuidString)" as NSString
        }
    }

    private func fetch(_ ref: ArtworkRef) -> Data? {
        guard let context = readContext() else { return nil }
        let id = ref.id
        switch ref {
        case .track:
            var d = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.artworkData
        case .album:
            var d = FetchDescriptor<AlbumEntity>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.artworkData
        case .artist:
            var d = FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.artworkData
        case .playlist:
            var d = FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.artworkData
        }
    }
}

// MARK: - Convenience

public extension ArtworkProvider {
    /// `explicit` is whatever the caller already holds — an online track's
    /// artwork, a freshly picked cover — and always wins. Only a nil falls
    /// through to the store.
    static func resolve(_ explicit: Data?, _ ref: ArtworkRef?) -> Data? {
        if let explicit, !explicit.isEmpty { return explicit }
        guard let ref else { return nil }
        return shared.data(for: ref)
    }
}

// MARK: - Domain sugar
//
// Every UI site that used to read `x.artworkData` directly — washes, colour
// extraction, hero images, export sheets — reads `x.displayArtwork` instead.
// It is the same value for a row the caller already holds art for, and the
// store lookup for one the bulk fetch skipped.

@MainActor
public extension Track {
    var displayArtwork: Data? { ArtworkProvider.resolve(artworkData, .track(id)) }
}

@MainActor
public extension Album {
    var displayArtwork: Data? { ArtworkProvider.resolve(artworkData, .album(id)) }
}

@MainActor
public extension Artist {
    var displayArtwork: Data? { ArtworkProvider.resolve(artworkData, .artist(id)) }
}

@MainActor
public extension Playlist {
    var displayArtwork: Data? { ArtworkProvider.resolve(artworkData, .playlist(id)) }
}
