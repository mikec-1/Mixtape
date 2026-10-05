// Proposed metadata from MetadataEnrichmentService, confirmed by the user
// before writing. Nil fields mean keep the existing value.

import Foundation

// MARK: - Source

public enum EnrichmentSource: Sendable {
    case itunes           // matched via iTunes Search API
    case filenameOnly     // parsed from filename; no API match found
    case existingMetadata  // already fully tagged
}

// MARK: - Candidate

public struct EnrichmentCandidate: Sendable {

    // Nil keeps the stored value.
    public var title:        String?
    public var artistName:   String?
    public var albumTitle:   String?
    public var year:         Int?
    public var genre:        String?
    public var trackNumber:  Int?

    /// Remote album artwork URL (600x600). Caller downloads and embeds on confirm.
    public var artworkURL:      URL?

    /// Artist photo from Deezer. Applied to the artist only, never as track art.
    public var artistImageURL:  URL?

    /// Match confidence 0.0-1.0
    public var confidence:   Double

    public var source:       EnrichmentSource

    // MARK: Convenience

    /// True when confidence is high enough to auto-show (not auto-apply) the sheet.
    public var isHighConfidence: Bool { confidence >= 0.6 }
}
