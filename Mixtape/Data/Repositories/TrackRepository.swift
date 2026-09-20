// TrackRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class TrackRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    /// The store every repository shares — the handle a caller needs to open a
    /// `RepositorySaveBatch` around a run of writes.
    public var modelContext: ModelContext { context }

    // MARK: - Fetch

    public func fetchAll() throws -> [Track] {
        var descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        // Everything `toDomain` reads except the cover. Artwork is stored inline
        // — a downsampled cover sits well under SwiftData's ~128 KB external
        // storage threshold — so a plain fetch materialises the whole library's
        // artwork up front, on the main thread, to publish an array that a
        // screenful of rows draws twenty pictures from.
        // `propertiesToFetch` is not "the properties I want" so much as "what to
        // prefetch eagerly". Naming the full scalar list makes Core Data pull the
        // whole row *including the artwork blob*; naming only the id leaves the
        // blob alone and batch-faults the scalars on access. Measured on a
        // 2088-track library: full list 490 MB at end of refresh, id only
        // 218 MB — and the id-only fetch was also the faster of the two.
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Track? {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    /// Every stored track among `ids`, keyed by id.
    ///
    /// One query instead of one per song. Saving a twenty-five-track mix asks
    /// "do I already have this?" twenty-five times, and each of those was a
    /// separate fetch against the whole table before this existed.
    ///
    /// Soft-deleted rows are included on purpose, unlike `fetchAll`: a caller
    /// deciding whether it may write over an id needs to see the tombstone
    /// sitting on it, not conclude the id is free.
    public func fetch(ids: [UUID]) throws -> [UUID: Track] {
        try fetchEntities(ids: ids).mapValues { $0.toDomain() }
    }

    /// The rows `fetchAll` hides.
    ///
    /// Only the deletion-repair path wants these. Everything else in the app is
    /// right to treat a soft-deleted track as gone — but a tombstone that was
    /// applied by mistake is invisible to every other query, so repairing it
    /// needs a way to look at the dead.
    public func fetchSoftDeleted() throws -> [Track] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.isSoftDeleted }
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    /// Returns track IDs that already have a given file hash (dedup check).
    public func existingIDs(forFileHash hash: String) throws -> [UUID] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileHash == hash && !$0.isSoftDeleted }
        )
        return try context.fetch(descriptor).map { $0.id }
    }

    // MARK: - Save

    public func save(_ track: Track) throws {
        // Upsert: update if exists, insert if new
        if let existing = try fetchEntity(id: track.id) {
            existing.update(from: track)
        } else {
            context.insert(TrackEntity(from: track))
        }
        try context.saveBatched()
    }

    /// Upserts many tracks as a single transaction.
    ///
    /// `save(_:)` commits once per track, so writing a mix meant twenty-five
    /// separate transactions for what is logically one change — and the user
    /// waited through every one of them on the main actor.
    public func save(_ tracks: [Track]) throws {
        guard !tracks.isEmpty else { return }
        let existing = try fetchEntities(ids: tracks.map(\.id))
        for track in tracks {
            if let entity = existing[track.id] {
                entity.update(from: track)
            } else {
                context.insert(TrackEntity(from: track))
            }
        }
        try context.saveBatched()
    }

    // MARK: - Delete

    /// Hard-deletes every TrackEntity from the local store.
    public func deleteAll() throws {
        try context.delete(model: TrackEntity.self)
        try context.saveBatched()
    }

    // MARK: - Delete (soft)

    public func softDelete(id: UUID) throws {
        guard let entity = try fetchEntity(id: id) else { return }
        mark(entity)
        try context.saveBatched()
    }

    /// Soft-deletes a whole selection in one fetch. Per-id, deleting a large
    /// import was thousands of predicate fetches on the main thread.
    ///
    /// Returns the ids that were actually found, so the caller doesn't have to
    /// ask again which ones existed.
    @discardableResult
    public func softDelete(ids: [UUID]) throws -> Set<UUID> {
        let found = try fetchEntities(ids: ids)
        for entity in found.values { mark(entity) }
        guard !found.isEmpty else { return [] }
        try context.saveBatched()
        return Set(found.keys)
    }

    private func mark(_ entity: TrackEntity) {
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
    }

    // MARK: - Private

    private func fetchEntity(id: UUID) throws -> TrackEntity? {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    private func fetchEntities(ids: [UUID]) throws -> [UUID: TrackEntity] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        return Dictionary(try context.fetch(descriptor).map { ($0.id, $0) },
                          uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Entity ↔ Domain Mapping

extension TrackEntity {


    /// Map SwiftData entity → domain struct.
    /// `includingArtwork: false` is the bulk-fetch path. The cover was left out
    /// of the fetch on purpose, and *reading* `artworkData` here would fault it
    /// straight back in one row at a time — the slow thing, done slower. Views
    /// ask `ArtworkProvider` for it instead.
    func toDomain(includingArtwork: Bool = true) -> Track {
        Track(
            id:           id,
            title:        title,
            artistName:   artistName,
            albumTitle:   albumTitle,
            duration:     duration,
            trackNumber:  trackNumber,
            discNumber:   discNumber,
            year:         year,
            genre:        genre,
            artworkData:  includingArtwork ? artworkData : nil,
            artworkKey:   artworkKey,
            composer:     composer,
            isExplicit:   isExplicit,
            dateImported: dateImported,
            sync: SyncMetadata(
                serverID:        syncServerID,
                status:          SyncStatus(rawValue: syncStatus) ?? .localOnly,
                localModifiedAt: syncLocalModifiedAt,
                serverModifiedAt: syncServerModifiedAt,
                lastSyncedAt:    syncLastSyncedAt,
                deviceID:        syncDeviceID
            ),
            file: FileProvenance(
                fileHash:    fileHash,
                fileSize:    fileSize,
                localPath:   localPath,
                remoteKey:   remoteKey,
                uploaded:    fileUploaded,
                downloadedAt: fileDownloadedAt,
                origin:      resolvedOrigin,
                sourceRef:   sourceRef
            ),
            isDeleted: isSoftDeleted
        )
    }

    /// The stored origin, or what the row's shape says it must have been before
    /// the field existed.
    var resolvedOrigin: TrackOrigin {
        if let raw = originRaw, let origin = TrackOrigin(rawValue: raw) { return origin }
        return FileProvenance.inferOrigin(
            localPath: localPath,
            fileHash:  fileHash,
            fileSize:  fileSize,
            remoteKey: remoteKey
        )
    }

    /// Update entity in-place from a domain struct (for upsert).
    func update(from track: Track) {
        title        = track.title
        artistName   = track.artistName
        albumTitle   = track.albumTitle
        duration     = track.duration
        trackNumber  = track.trackNumber
        discNumber   = track.discNumber
        year         = track.year
        genre        = track.genre
        // A domain struct from the bulk fetch carries no cover — nil here
        // means "wasn't loaded", never "delete it". Clearing artwork is done
        // on the entity directly.
        if let art = track.artworkData { artworkData = art }
        artworkKey   = track.artworkKey
        composer     = track.composer
        isExplicit   = track.isExplicit
        isSoftDeleted = track.isDeleted

        syncStatus           = track.sync.status.rawValue
        syncServerID         = track.sync.serverID
        syncDeviceID         = track.sync.deviceID
        syncLocalModifiedAt  = track.sync.localModifiedAt
        syncServerModifiedAt = track.sync.serverModifiedAt
        syncLastSyncedAt     = track.sync.lastSyncedAt

        fileHash         = track.file.fileHash
        fileSize         = track.file.fileSize
        localPath        = track.file.localPath
        remoteKey        = track.file.remoteKey
        fileUploaded     = track.file.uploaded
        fileDownloadedAt = track.file.downloadedAt
        originRaw        = track.file.origin.rawValue
        sourceRef        = track.file.sourceRef
    }
}

extension TrackEntity {
    /// Create entity from a domain struct (for insert).
    convenience init(from track: Track) {
        self.init(
            id:           track.id,
            title:        track.title,
            artistName:   track.artistName,
            albumTitle:   track.albumTitle,
            duration:     track.duration,
            trackNumber:  track.trackNumber,
            discNumber:   track.discNumber,
            year:         track.year,
            genre:        track.genre,
            artworkData:  track.artworkData,
            artworkKey:   track.artworkKey,
            composer:     track.composer,
            isExplicit:   track.isExplicit,
            dateImported: track.dateImported,
            isSoftDeleted: track.isDeleted,
            fileHash:     track.file.fileHash,
            fileSize:     track.file.fileSize,
            localPath:    track.file.localPath,
            remoteKey:    track.file.remoteKey,
            fileUploaded: track.file.uploaded,
            fileDownloadedAt: track.file.downloadedAt,
            originRaw:    track.file.origin.rawValue,
            sourceRef:    track.file.sourceRef,
            syncStatus:           track.sync.status.rawValue,
            syncServerID:         track.sync.serverID,
            syncDeviceID:         track.sync.deviceID,
            syncLocalModifiedAt:  track.sync.localModifiedAt,
            syncServerModifiedAt: track.sync.serverModifiedAt,
            syncLastSyncedAt:     track.sync.lastSyncedAt
        )
    }
}
