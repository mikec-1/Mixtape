// MetadataReviewItem.swift
// Mixtape — Core/Services/Enrichment
//
// Represents one pending metadata review, held in MacAppState's review queue.
// When the user imports a track and the enrichment service finds a candidate,
// a MetadataReviewItem is enqueued and the review sheet is shown.
//
// The candidate here is the *starting* one, and for a file import it's the
// filename reading — cheap, local, immediate. Import used to await the iTunes
// lookup before it could hand anything back, which meant the sheet appeared
// around ten seconds after the drop: long enough for the user to move on and
// be surprised by it. The lookup now runs from the sheet, which is up straight
// away, and folds its answer in when it lands.

import Foundation

public struct MetadataReviewItem: Identifiable, Sendable {

    /// The inputs the iTunes lookup needs, when there's still one worth doing.
    ///
    /// Nil once the answer can't improve: metadata that's already complete, or
    /// an online import that arrived with correct tags.
    ///
    /// `sourceURL` is only ever read for its *name* — the enrichment service
    /// parses the filename and never opens the file — so it stays usable after
    /// the import's security-scoped access has been given back.
    public struct Lookup: Sendable {
        public let sourceURL: URL
        public let existing:  ParsedMetadata

        public init(sourceURL: URL, existing: ParsedMetadata) {
            self.sourceURL = sourceURL
            self.existing  = existing
        }
    }

    public let id:        UUID
    public let track:     Track
    public let candidate: EnrichmentCandidate
    public let lookup:    Lookup?

    public init(track: Track, candidate: EnrichmentCandidate, lookup: Lookup? = nil) {
        self.id        = UUID()
        self.track     = track
        self.candidate = candidate
        self.lookup    = lookup
    }
}
