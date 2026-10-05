// Loads artwork per row on demand. Bulk fetches skip the blob to save memory.
// A Track's own artworkData still wins when set.

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

    /// Blob reads go through a scratch context that's reset regularly, so faulted
    /// blobs don't stay resident like they would on the main context.
    private var scratch: ModelContext?
    private var readsSinceReset = 0

    private static let readsBeforeReset = 150

    private init() {
        // Encoded bytes. Decoded bitmaps are ArtworkDecodeCache's budget.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// Recycled periodically. Never held across an account switch.
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

    /// Forgets one row so the next draw re-reads it.
    public func invalidate(_ ref: ArtworkRef) {
        invalidate([ref])
    }

    public func invalidate(_ refs: some Sequence<ArtworkRef>) {
        var emptied = false
        for ref in refs {
            emptied = true
            cache.removeObject(forKey: Self.key(ref))
        }
        // The scratch context would return stale rows.
        if emptied { scratch = nil }
    }

    /// Misses aren't cached since artwork often arrives later.
    public func data(for ref: ArtworkRef) -> Data? {
        let key = Self.key(ref)
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let data = fetch(ref), !data.isEmpty else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        recycleIfNeeded()
        return data
    }

    /// For bulk jobs like Spotlight, bypasses the cache.
    public func uncachedData(for ref: ArtworkRef) -> Data? {
        defer { recycleIfNeeded() }
        return fetch(ref)
    }

    /// Track ids that have a cover, without reading blobs.
    public func trackIDsWithArtwork() -> Set<UUID> {
        guard let context = readContext() else { return [] }
        var d = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkData != nil && !$0.isSoftDeleted }
        )
        d.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(d)) ?? []).map(\.id))
    }

    /// Track ids without a cover.
    public func trackIDsWithoutArtwork() -> [UUID] {
        guard let context = readContext() else { return [] }
        var d = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkData == nil && !$0.isSoftDeleted }
        )
        d.propertiesToFetch = [\.id]
        return ((try? context.fetch(d)) ?? []).map(\.id)
    }

    /// Track ids whose cover is smaller than maxDimension. Reads image headers
    /// in pages.
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
    /// The caller's own data wins, nil falls through to the store.
    static func resolve(_ explicit: Data?, _ ref: ArtworkRef?) -> Data? {
        if let explicit, !explicit.isEmpty { return explicit }
        guard let ref else { return nil }
        return shared.data(for: ref)
    }
}

// MARK: - Domain sugar
// UI reads `displayArtwork`: the held blob, or a store lookup.

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
