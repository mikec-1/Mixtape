// Favorite.swift
// Mixtape — Core Domain Models

import Foundation

public struct Favorite: Identifiable, Codable, Hashable, Sendable {

    public let id: UUID
    public let trackID: UUID
    public let addedAt: Date

    // Sync
    public var sync: SyncMetadata

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        addedAt: Date = Date(),
        sync: SyncMetadata
    ) {
        self.id      = id
        self.trackID = trackID
        self.addedAt = addedAt
        self.sync    = sync
    }
}
