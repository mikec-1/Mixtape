// One pending metadata review in MacAppState's queue. The candidate starts as
// the filename reading so the sheet opens straight away; the iTunes lookup runs
// from the sheet and folds in when it lands.

import Foundation

public struct MetadataReviewItem: Identifiable, Sendable {

    /// What the iTunes lookup needs, or nil when it can't improve anything.
    /// Only sourceURL's name is read, so it's fine after security-scoped access ends.
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
    /// Opened from Edit Metadata, so Skip reads Cancel.
    public private(set) var isEdit = false

    public init(track: Track, candidate: EnrichmentCandidate, lookup: Lookup? = nil) {
        self.id        = UUID()
        self.track     = track
        self.candidate = candidate
        self.lookup    = lookup
    }

    /// A review on the tags a song arrived with. Link imports.
    public init(imported track: Track) {
        self.init(track: track, candidate: EnrichmentCandidate(confidence: 1.0, source: .existingMetadata))
    }

    /// Edit Metadata on a song already in the library.
    public init(editing track: Track) {
        self.init(imported: track)
        isEdit = true
    }
}
