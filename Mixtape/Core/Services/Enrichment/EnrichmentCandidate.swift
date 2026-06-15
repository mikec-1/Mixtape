// EnrichmentCandidate.swift
// Mixtape — Core/Services/Enrichment
//
// The proposed metadata returned by MetadataEnrichmentService.
// nil fields mean "no suggestion — keep existing value".
// The UI shows this to the user for confirmation before writing.

import Foundation

// MARK: - Source

public enum EnrichmentSource: Sendable {
    case itunes           // matched via iTunes Search API
    case filenameOnly     // parsed from filename; no API match found
    case existingMetadata // track already had complete tags — passthrough review
}

// MARK: - Candidate

public struct EnrichmentCandidate: Sendable {

    // Proposed values — nil = keep whatever is already stored
    public var title:        String?
    public var artistName:   String?
    public var albumTitle:   String?
    public var year:         Int?
    public var genre:        String?
    public var trackNumber:  Int?

    /// Remote album artwork URL (600×600). Caller downloads and embeds on confirm.
    public var artworkURL:      URL?

    /// Remote artist profile photo URL (from Deezer). Separate from album art.
    /// Applied to the artist entity only — never used as track/album artwork.
    public var artistImageURL:  URL?

    /// Match confidence 0.0 – 1.0
    public var confidence:   Double

    public var source:       EnrichmentSource

    // MARK: Convenience

    /// True when confidence is high enough to auto-show (not auto-apply) the sheet.
    public var isHighConfidence: Bool { confidence >= 0.6 }
}
