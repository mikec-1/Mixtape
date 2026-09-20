// MetadataDraft.swift
// Mixtape — Core/Services/Enrichment
//
// The six editable fields of a review sheet, plus the one rule that makes a
// late-arriving lookup safe: never overwrite something the user has typed.
//
// The sheet now opens on the filename reading and the iTunes answer lands a
// few seconds later, while the user may already be fixing a title. Without a
// record of what the fields held when they were last filled in, "the answer
// arrived" and "the user changed their mind" are indistinguishable, and the
// good outcome is the one where their correction quietly disappears.
//
// Both sheets used to carry their own copy of the identical init/reset code.
// One type, so the Mac and iOS sheets can't drift apart on the rule.

import Foundation

struct MetadataDraft: Equatable {

    struct Fields: Equatable {
        var title    = ""
        /// Primary artist only — the track is filed under this artist folder.
        var artist   = ""
        /// Everything after the & / ft. / feat. separator. Empty when there's
        /// no feature. Recombined with `artist` on Apply.
        var featured = ""
        var album    = ""
        var year     = ""
        var genre    = ""
    }

    var fields = Fields()

    /// What the fields held the last time they were filled from a candidate.
    /// A field still equal to this is untouched; anything else is the user's.
    private var baseline = Fields()

    init() {}

    init(candidate: EnrichmentCandidate, track: Track) {
        reset(to: candidate, track: track)
    }

    /// Starts over on a new song. Used when the review queue advances.
    mutating func reset(to candidate: EnrichmentCandidate, track: Track) {
        fields   = Self.fields(from: candidate, track: track)
        baseline = fields
    }

    /// Folds a better candidate into the same song's draft.
    mutating func merge(_ candidate: EnrichmentCandidate, track: Track) {
        let incoming = Self.fields(from: candidate, track: track)
        for key in Self.editable { merge(key, incoming) }
    }

    private static let editable: [WritableKeyPath<Fields, String>] =
        [\.title, \.artist, \.featured, \.album, \.year, \.genre]

    private mutating func merge(_ key: WritableKeyPath<Fields, String>, _ incoming: Fields) {
        let new = incoming[keyPath: key]
        // Silence isn't an improvement. iTunes often has no genre and no year,
        // and blanking what the file itself carried would be a downgrade.
        guard !new.isEmpty else { return }
        guard fields[keyPath: key] == baseline[keyPath: key] else { return }
        fields[keyPath: key]   = new
        baseline[keyPath: key] = new
    }

    private static func fields(from candidate: EnrichmentCandidate, track: Track) -> Fields {
        let raw = candidate.artistName ?? track.artistName
        let (primary, featured) = ImportService.splitArtist(from: raw)
        return Fields(
            title:    candidate.title ?? track.title,
            artist:   primary,
            featured: featured ?? "",
            album:    candidate.albumTitle ?? track.albumTitle,
            year:     (candidate.year ?? track.year).map(String.init) ?? "",
            genre:    candidate.genre ?? track.genre ?? ""
        )
    }

    // MARK: - Apply

    /// The artist string as stored on the track: primary, plus the feature when
    /// there is one. The track is always filed under `primaryArtist`.
    var fullArtist: String {
        let primary  = primaryArtist
        let featured = fields.featured.trimmingCharacters(in: .whitespaces)
        return featured.isEmpty ? primary : "\(primary) ft. \(featured)"
    }

    var primaryArtist: String {
        fields.artist.trimmingCharacters(in: .whitespaces)
    }
}
