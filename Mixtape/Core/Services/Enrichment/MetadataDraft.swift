// The six editable fields of a review sheet. The iTunes answer can land after
// the user has started typing, so a field is only refilled if it still holds
// what we last put there. Shared by the Mac and iOS sheets.

import Foundation

struct MetadataDraft: Equatable {

    struct Fields: Equatable {
        var title    = ""
        /// Primary artist, used for the folder.
        var artist   = ""
        /// Everything after & / ft. / feat. Empty when there's no feature.
        var featured = ""
        var album    = ""
        var year     = ""
        var genre    = ""
    }

    var fields = Fields()

    /// What the fields held when last filled. Anything different is the user's.
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
        // Don't blank what the file had when iTunes has nothing.
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

    /// Primary plus feature, as stored on the track.
    var fullArtist: String {
        let primary  = primaryArtist
        let featured = fields.featured.trimmingCharacters(in: .whitespaces)
        return featured.isEmpty ? primary : "\(primary) ft. \(featured)"
    }

    var primaryArtist: String {
        fields.artist.trimmingCharacters(in: .whitespaces)
    }
}
