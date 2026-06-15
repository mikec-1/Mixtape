// PlayHistoryEntry.swift
// Mixtape — Core Domain Models

import Foundation

public struct PlayHistoryEntry: Identifiable, Codable, Hashable, Sendable {

    public let id: UUID
    /// The track that was played.
    public let trackID: UUID
    /// When playback started (wall clock).
    public let playedAt: Date
    /// How many seconds were actually played before the user skipped / stopped.
    /// Used to distinguish a deliberate listen from an accidental tap.
    public var secondsPlayed: TimeInterval

    // Sync
    public var sync: SyncMetadata

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        playedAt: Date = Date(),
        secondsPlayed: TimeInterval = 0,
        sync: SyncMetadata
    ) {
        self.id            = id
        self.trackID       = trackID
        self.playedAt      = playedAt
        self.secondsPlayed = secondsPlayed
        self.sync          = sync
    }

    /// A play counts toward "Recently Played" only if the user listened for > 30 seconds.
    public var countsAsPlay: Bool { secondsPlayed > 30 }
}
