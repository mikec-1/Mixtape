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

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    private let limit = 2_000

    public init() {}

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

    /// Drops the snapshot for one id.
    ///
    /// A Discover song the user deletes has to lose this too: the snapshot is
    /// what "Recently played" resolves against after a relaunch, so leaving it
    /// behind brings the deleted song back on the next launch.
    public func delete(id: UUID) throws {
        try delete(ids: [id])
    }

    /// One fetch for a whole selection: a bulk library delete calls this once
    /// per song otherwise.
    public func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        var deleted = false
        for row in try context.fetch(FetchDescriptor<PlayedTrackSnapshotEntity>())
        where ids.contains(row.id) {
            context.delete(row)
            deleted = true
        }
        guard deleted else { return }
        try context.save()
    }

    /// Drops every snapshot. These outlive the library on purpose — a Discover
    /// track never had a TrackEntity to delete — which is exactly why wiping the
    /// library alone leaves stats resolving names that aren't in it any more.
    public func deleteAll() throws {
        try context.delete(model: PlayedTrackSnapshotEntity.self)
        try context.save()
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
    /// Reconstruct a display/replayable `Track`. A history snapshot only ever
    /// exists for a Discover play, so the row is `.online` and carries the key
    /// that resolves it again.
    func asTrack(deviceID: String) -> Track {
        var provenance = FileProvenance.onlinePlaceholder(sourceRef: sourceKey)
        provenance.fileHash = sourceKey
        return Track(
            id: id,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkData: artworkData,
            sync: SyncMetadata(deviceID: deviceID),
            file: provenance
        )
    }
}
