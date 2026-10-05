import Foundation
import SwiftData

@MainActor
public final class TrackRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    /// The shared context, for opening a `RepositorySaveBatch`.
    public var modelContext: ModelContext { context }

    // MARK: - Fetch

    public func fetchAll() throws -> [Track] {
        var descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        // Only the id. Naming more properties makes Core Data prefetch the whole row,
        // artwork included; with just the id, scalars fault in on access and covers stay
        // on disk. Far less memory and faster on a large library.
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Track? {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    /// Stored tracks among `ids`, keyed by id, in one query.
    /// Includes soft-deleted rows, unlike `fetchAll`: a caller deciding whether it
    /// may write an id needs to see the tombstone.
    public func fetch(ids: [UUID]) throws -> [UUID: Track] {
        try fetchEntities(ids: ids).mapValues { $0.toDomain() }
    }

    /// Soft-deleted tracks, for the deletion-repair path only.
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

    /// Upserts many tracks in one transaction.
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

    /// Soft-deletes a selection in one fetch. Returns the ids that were found.
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

// MARK: - Entity <-> Domain Mapping

extension TrackEntity {


    /// Entity -> domain struct. `includingArtwork: false` is the bulk path: reading
    /// `artworkData` would fault the cover in row by row. Views use `ArtworkProvider`.
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
            isDeleted: isSoftDeleted,
            edit: editData.flatMap { try? JSONDecoder().decode(SongEdit.self, from: $0) }
        )
    }

    /// Stored origin, or inferred from the row for rows older than the field.
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
        // Nil from a bulk-fetched struct means "not loaded", not "delete".
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
        // Nil keeps the stored recipe; a Track built without one shouldn't wipe it.
        if let edit = track.edit { editData = try? JSONEncoder().encode(edit) }
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
        editData = track.edit.flatMap { try? JSONEncoder().encode($0) }
    }
}
