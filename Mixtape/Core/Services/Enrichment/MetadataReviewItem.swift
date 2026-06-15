// MetadataReviewItem.swift
// Mixtape — Core/Services/Enrichment
//
// Represents one pending metadata review, held in MacAppState's review queue.
// When the user imports a track and the enrichment service finds a candidate,
// a MetadataReviewItem is enqueued and the review sheet is shown.

import Foundation

public struct MetadataReviewItem: Identifiable, Sendable {
    public let id:        UUID
    public let track:     Track
    public let candidate: EnrichmentCandidate

    public init(track: Track, candidate: EnrichmentCandidate) {
        self.id        = UUID()
        self.track     = track
        self.candidate = candidate
    }
}
