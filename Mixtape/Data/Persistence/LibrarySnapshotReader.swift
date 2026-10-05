// Reads the whole library off the main actor.
// The repositories share the main context, which suits writes but makes the
// launch-time full read block the UI. This runs the same fetches on a private
// context and returns only `Sendable` value types. Artwork is left out, as in
// `TrackRepository.fetchAll`.

import Foundation
import SwiftData
import OSLog

/// One consistent read of the three bulk collections.
public struct LibrarySnapshot: Sendable {
    public let tracks:  [Track]
    public let albums:  [Album]
    public let artists: [Artist]
    /// Ids of live tracks with a stored cover, so the main actor doesn't have to
    /// compute it. Nil means the caller should work it out itself.
    public let tracksWithArtwork: Set<UUID>?
    /// Fetch time, for logging.
    public let fetchMilliseconds: Int
}

/// Not an actor: `@ModelActor`'s executor runs jobs inline on the caller's
/// thread, so an await from main still ran on main. Instead `read()` creates and
/// drops its own context inside a detached task.
public final class LibrarySnapshotReader: Sendable {

    public init() {}

    /// Tracks, albums and artists in one call so all three see the same store state.
    /// `container` is passed in because it belongs to whichever account's store is
    /// open right now. See `ModelStore`.
    public func read(container: ModelContainer) async throws -> LibrarySnapshot {
        // `Task.detached` because under SE-0461 a `nonisolated async` func runs on the
        // caller's actor, which would be main here. Only value types come back.
        return try await Task.detached(priority: .userInitiated) {
            try Self.readSynchronously(container: container)
        }.value
    }

    private nonisolated static func readSynchronously(container modelContainer: ModelContainer) throws -> LibrarySnapshot {
        let started = CFAbsoluteTimeGetCurrent()

        // Catches a regression back onto the main thread, which is otherwise silent.
        if Thread.isMainThread {
            MixLog.database.error("LibrarySnapshotReader.read() is running ON THE MAIN THREAD")
        }

        var trackDescriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        trackDescriptor.propertiesToFetch = [\.id]

        var albumDescriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        albumDescriptor.propertiesToFetch = [\.id]

        var artistDescriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.name)]
        )
        artistDescriptor.propertiesToFetch = [\.id]

        // A scratch context per read: a context keeps every fetched row alive, so a
        // long-lived one would hold a second copy of the library. Same as
        // `ArtworkProvider.scratch`.
        let scratch = ModelContext(modelContainer)

        // Timed separately: unfetched scalars fault back to the store in `toDomain`,
        // so the map may cost more than the fetch.
        let fetchedAt = CFAbsoluteTimeGetCurrent()
        let trackRows = try scratch.fetch(trackDescriptor)
        let rowsAt    = CFAbsoluteTimeGetCurrent()
        let tracks    = trackRows.map { $0.toDomain(includingArtwork: false) }
        let mappedAt  = CFAbsoluteTimeGetCurrent()

        var coverDescriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkData != nil && !$0.isSoftDeleted }
        )
        coverDescriptor.propertiesToFetch = [\.id]
        let covers = Set((try scratch.fetch(coverDescriptor)).map(\.id))

        let coversAt = CFAbsoluteTimeGetCurrent()

        let albums  = try scratch.fetch(albumDescriptor).map  { $0.toDomain(includingArtwork: false) }
        let albumsAt = CFAbsoluteTimeGetCurrent()
        let artists = try scratch.fetch(artistDescriptor).map { $0.toDomain(includingArtwork: false) }
        let artistsAt = CFAbsoluteTimeGetCurrent()

        func ms(_ a: CFAbsoluteTime, _ b: CFAbsoluteTime) -> Int { Int((b - a) * 1000) }
        MixLog.database.notice("""
            library-fetch breakdown — \
            tracks fetch \(ms(fetchedAt, rowsAt), privacy: .public) ms, \
            map \(ms(rowsAt, mappedAt), privacy: .public) ms; \
            covers \(ms(mappedAt, coversAt), privacy: .public) ms; \
            albums \(ms(coversAt, albumsAt), privacy: .public) ms; \
            artists \(ms(albumsAt, artistsAt), privacy: .public) ms
            """)

        return LibrarySnapshot(
            tracks:  tracks,
            albums:  albums,
            artists: artists,
            tracksWithArtwork: covers,
            fetchMilliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        )
    }
}
