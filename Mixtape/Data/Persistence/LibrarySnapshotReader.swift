// LibrarySnapshotReader.swift
// Mixtape — Data/Persistence
//
// Reads the whole library off the main actor.
//
// The repositories are all `@MainActor` and share the container's `mainContext`,
// which is the right shape for the write paths — they run inside a user action
// that is already on the main actor and want their change visible to the very
// next read. It is the wrong shape for the one read that dominates launch:
// `LibraryService.refresh()` pulls every track, album and artist, and at ~2,100
// tracks that is roughly a second of main-thread time during which the Library
// tab cannot draw a frame.
//
// This is the same three fetches against a *private* context vended by
// `@ModelActor`, which pins the actor's executor to that context so the rows are
// only ever touched from one place. Nothing here writes, and nothing crosses the
// boundary but value types: `Track`, `Album` and `Artist` are `Sendable` structs
// that `toDomain` has already detached from their entities.
//
// Artwork is left behind, exactly as the repositories leave it — see
// `TrackRepository.fetchAll` for why naming only `\.id` in `propertiesToFetch`
// is what keeps the cover blobs out of the fetch.

import Foundation
import SwiftData
import OSLog

/// One consistent read of the three bulk collections.
public struct LibrarySnapshot: Sendable {
    public let tracks:  [Track]
    public let albums:  [Album]
    public let artists: [Artist]
    /// Ids of the live tracks that have a cover stored.
    ///
    /// Computed here so the main actor never has to: the equivalent question on
    /// the main actor is a full-table fetch with a predicate against an
    /// external-storage attribute, and it used to run inside every `tracks =`
    /// assignment.
    /// `nil` from a caller that didn't compute it, which means "work it out on
    /// the main actor as before".
    public let tracksWithArtwork: Set<UUID>?
    /// How long the fetch itself took, so the caller can log it the same way the
    /// main-actor path does.
    public let fetchMilliseconds: Int
}

/// Deliberately **not** a `@ModelActor`, and not an actor at all.
///
/// It was one, and the read still ran on the main thread. `@ModelActor` installs
/// SwiftData's `DefaultSerialModelExecutor`, which runs an enqueued job inline on
/// the enqueuing thread rather than hopping — so a `read()` awaited from the main
/// actor executed on the main thread through `NSManagedObjectContext.performAndWait`,
/// and the "off-main" fetch froze the app for the whole ~650 ms. Building the actor
/// off the main actor made no difference, because the thread comes from the caller,
/// not from where the context was created.
///
/// So there is no actor and no custom executor here. `read()` is `nonisolated async`,
/// which under SE-0338 does not inherit the caller's actor and runs on the shared
/// concurrent pool; it does its work in one synchronous call, creating and dropping
/// its `ModelContext` on that pool thread. The context therefore never escapes the
/// call, which is what made the actor necessary in the first place.
public final class LibrarySnapshotReader: Sendable {

    public init() {}

    /// Fetches tracks, albums and artists off the main actor.
    ///
    /// Deliberately one call rather than three: the three fetches want to see the
    /// same store state, and going back to the caller between them would let a
    /// main-actor write land in the middle and produce a snapshot whose albums
    /// reference tracks it doesn't contain.
    /// `container` is passed in rather than held: it belongs to whichever
    /// account's store is open at the moment of the call. See `ModelStore`.
    public func read(container: ModelContainer) async throws -> LibrarySnapshot {
        // `Task.detached`, and not `nonisolated async`, because Swift 6.2
        // reversed the rule this file used to rely on. Under SE-0338 a
        // `nonisolated async` function ran on the generic executor; under
        // SE-0461 it runs on the **caller's** actor, so awaiting it from
        // `LibraryService` (which is `@MainActor`) kept the whole fetch on the
        // main thread — the canary below printed on every single sync, through
        // both the `@ModelActor` version and the `nonisolated async` one.
        //
        // `Task.detached` still inherits no isolation in 6.2, which is the
        // property actually needed here. The container is `Sendable`, the
        // context is created and dropped inside the detached body, and only
        // value types come back.
        return try await Task.detached(priority: .userInitiated) {
            try Self.readSynchronously(container: container)
        }.value
    }

    private nonisolated static func readSynchronously(container modelContainer: ModelContainer) throws -> LibrarySnapshot {
        let started = CFAbsoluteTimeGetCurrent()

        // The canary that caught the `@ModelActor` version. The failure mode is
        // completely silent otherwise — the work still finishes, it just freezes
        // the app doing it.
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

        // A scratch context per read, not the actor's own. A `ModelContext` keeps
        // every row it fetches registered for as long as it lives, so reading the
        // whole library through the actor's long-lived context would leave a
        // second copy of it resident between refreshes. This one is created and
        // dropped inside a single synchronous, actor-isolated call — the rows go
        // with it, and the caller keeps only the structs. Same reasoning as
        // `ArtworkProvider.scratch`.
        let scratch = ModelContext(modelContainer)

        // Split deliberately. `propertiesToFetch = [\.id]` keeps the cover blob
        // out of the fetch, but `toDomain` then reads twenty-two other scalars
        // off each row — and a property that wasn't fetched is a fault back to
        // the store. If that is what the Mac's 4.3-second read is, the fetch
        // will be quick and the map will be almost all of it.
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
