// TrackRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class TrackRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetch

    public func fetchAll() throws -> [Track] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func fetch(id: UUID) throws -> Track? {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
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
        try context.save()
    }

    // MARK: - Delete

    /// Hard-deletes every TrackEntity from the local store.
    public func deleteAll() throws {
        try context.delete(model: TrackEntity.self)
        try context.save()
    }

    // MARK: - Delete (soft)

    public func softDelete(id: UUID) throws {
        guard let entity = try fetchEntity(id: id) else { return }
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
        try context.save()
    }

    // MARK: - Private

    private func fetchEntity(id: UUID) throws -> TrackEntity? {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Entity ↔ Domain Mapping

extension TrackEntity {
    /// Map SwiftData entity → domain struct.
    func toDomain() -> Track {
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
            artworkData:  artworkData,
            artworkKey:   artworkKey,
            composer:     composer,
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
                downloadedAt: fileDownloadedAt
            ),
            isDeleted: isSoftDeleted
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
        artworkData  = track.artworkData
        artworkKey   = track.artworkKey
        composer     = track.composer
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
            dateImported: track.dateImported,
            isSoftDeleted: track.isDeleted,
            fileHash:     track.file.fileHash,
            fileSize:     track.file.fileSize,
            localPath:    track.file.localPath,
            remoteKey:    track.file.remoteKey,
            fileUploaded: track.file.uploaded,
            fileDownloadedAt: track.file.downloadedAt,
            syncStatus:           track.sync.status.rawValue,
            syncServerID:         track.sync.serverID,
            syncDeviceID:         track.sync.deviceID,
            syncLocalModifiedAt:  track.sync.localModifiedAt,
            syncServerModifiedAt: track.sync.serverModifiedAt,
            syncLastSyncedAt:     track.sync.lastSyncedAt
        )
    }
}
