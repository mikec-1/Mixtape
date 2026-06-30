// PlayedTrackSnapshotRepository.swift
// Mixtape
//
// CRUD for PlayedTrackSnapshotEntity — snapshots of played Discover tracks that
// aren't in the library, so "Recently played" and stats can resolve them after a
// relaunch (they have no TrackEntity). Bounded so it can't grow forever.

import Foundation
import SwiftData

@MainActor
public final class PlayedTrackSnapshotRepository {

    private let context: ModelContext
    private let limit = 2_000

    public init(context: ModelContext) {
        self.context = context
    }

    /// Insert or update the snapshot for `track`, keyed by its (stable) id.
    public func upsert(_ track: Track) throws {
        let id = track.id
        let existing = try context.fetch(
            FetchDescriptor<PlayedTrackSnapshotEntity>(predicate: #Predicate { $0.id == id })
        ).first

        if let existing {
            existing.title       = track.title
            existing.artistName  = track.artistName
            existing.albumTitle  = track.albumTitle
            existing.duration    = track.duration
            if let art = track.artworkData { existing.artworkData = art }
            existing.sourceKey   = track.file.fileHash
            existing.updatedAt   = Date()
        } else {
            context.insert(PlayedTrackSnapshotEntity(
                id:          id,
                title:       track.title,
                artistName:  track.artistName,
                albumTitle:  track.albumTitle,
                duration:    track.duration,
                artworkData: track.artworkData,
                sourceKey:   track.file.fileHash
            ))
            try pruneIfNeeded()
        }
        try context.save()
    }

    /// All snapshots as ready-to-use `Track` values, keyed by id.
    public func fetchAll() throws -> [UUID: Track] {
        let rows = try context.fetch(FetchDescriptor<PlayedTrackSnapshotEntity>())
        var map: [UUID: Track] = [:]
        for row in rows { map[row.id] = row.asTrack(deviceID: "snapshot") }
        return map
    }

    private func pruneIfNeeded() throws {
        var desc = FetchDescriptor<PlayedTrackSnapshotEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        desc.fetchLimit = limit + 100
        let all = try context.fetch(desc)
        guard all.count > limit else { return }
        for row in all.dropFirst(limit) { context.delete(row) }
    }
}

extension PlayedTrackSnapshotEntity {
    /// Reconstruct a display/replayable `Track`. Empty localPath + nil remoteKey
    /// keep it classified as a standalone online track (see
    /// OnlinePlaybackCoordinator.isStandaloneOnline).
    func asTrack(deviceID: String) -> Track {
        Track(
            id: id,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkData: artworkData,
            sync: SyncMetadata(deviceID: deviceID),
            file: FileProvenance(fileHash: sourceKey, fileSize: 0, localPath: "")
        )
    }
}
