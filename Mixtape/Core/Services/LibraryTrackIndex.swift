// "Do I already have this song?" for imports from Spotify, mixes and shared
// playlists. Matches the recording (folded title, primary artist, duration)
// rather than the row id, since catalogues spell songs differently.
// Build one per import and throw it away.

import Foundation

public struct LibraryTrackIndex: Sendable {

    /// Library tracks by match key. Usually one per group.
    private var byKey: [String: [Track]] = [:]

    /// Enough slack for a fade or silence, not for a radio edit vs a club mix.
    private static let durationSlack: TimeInterval = 15

    public init(tracks: [Track]) {
        for track in tracks where !track.isDeleted && !track.isUnresolvableShare {
            byKey[Self.key(title: track.title, artistName: track.artistName), default: []]
                .append(track)
        }
    }

    /// The library's copy of this song. A duration of 0 matches on name alone.
    public func match(title: String, artistName: String, duration: TimeInterval) -> Track? {
        let candidates = byKey[Self.key(title: title, artistName: artistName)] ?? []
        guard !candidates.isEmpty else { return nil }
        guard duration > 0 else { return candidates.first }

        return candidates
            .filter { $0.duration <= 0 || abs($0.duration - duration) <= Self.durationSlack }
            .min { abs($0.duration - duration) < abs($1.duration - duration) }
    }

    /// Adds a row written during this import so repeats in one playlist land once.
    public mutating func insert(_ track: Track) {
        byKey[Self.key(title: track.title, artistName: track.artistName), default: []]
            .append(track)
    }

    // MARK: - Identity

    public static func key(title: String, artistName: String) -> String {
        normalisedTitle(title) + "|" + normalisedArtist(artistName)
    }

    /// The primary artist only, since catalogues disagree on where guests go.
    private static func normalisedArtist(_ raw: String) -> String {
        fold(ImportService.creditedArtists(from: raw).first ?? raw)
    }

    /// Drops the guest credit and remaster stamp, keeps Live/Acoustic/etc, then folds.
    private static func normalisedTitle(_ raw: String) -> String {
        // Skip the regexes for titles that can't match. That's most of them.
        guard containsPressingMarker(raw) else { return fold(raw) }

        var text = raw

        // "(feat. X)", "[ft. Y & Z]", "(2011 Remaster)"
        text = text.replacingOccurrences(
            of: #"[\(\[][^\)\]]*\b(feat\.?|ft\.?|featuring|w/|remaster(ed)?)\b[^\)\]]*[\)\]]"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive])

        // " - Remastered 2009", " - 2011 Remaster", " - Mono Version"
        text = text.replacingOccurrences(
            of: #"\s[-–]\s[^-–]*\b(remaster(ed)?|mono|stereo)\b[^-–]*$"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive])

        // A bare, unbracketed credit tail: "Song feat. X".
        text = text.replacingOccurrences(
            of: #"\s\b(feat\.?|ft\.?|featuring)\b.*$"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive])

        return fold(text)
    }

    /// Over-inclusive on purpose: a false positive just costs a regex pass.
    private static let pressingMarkers = ["feat", "ft", "w/", "remaster", "mono", "stereo"]

    private static func containsPressingMarker(_ raw: String) -> Bool {
        pressingMarkers.contains { raw.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Ignore case, accents and punctuation.
    private static func fold(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let stripped = String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return stripped.split(separator: " ").joined(separator: " ")
    }
}
