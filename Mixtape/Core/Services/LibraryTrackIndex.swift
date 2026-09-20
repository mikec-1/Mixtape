// LibraryTrackIndex.swift
// Mixtape — Core/Services
//
// "Do I already have this song?", for every path that pours songs into the
// library from somewhere else: a Spotify playlist, a saved mix, someone else's
// public playlist.
//
// Those paths used to answer that question with the track's id alone, and the id
// of an online song is derived from "title|artist" — so it only ever recognised
// a song the library had acquired *the same way*, spelled *exactly* the same. A
// user who owned "Bad Habit" as a file, or who had saved it from Deezer where it
// is filed a hair differently from Spotify ("Song (feat. X)" vs "Song"), got a
// second copy of every song in the playlist they imported.
//
// So identity here is the recording, not the row: a folded title and the act it
// is filed under, with the duration as a tiebreak. The index is a snapshot —
// build one, use it for the length of one import, throw it away.

import Foundation

public struct LibraryTrackIndex: Sendable {

    /// Every live track in the library, grouped by match key. A group usually
    /// holds one row; it holds more when the same song is in there twice
    /// already, or when two genuinely different recordings share a name.
    private var byKey: [String: [Track]] = [:]

    /// How far apart two runtimes for "the same song" may be. Wide enough for a
    /// rip that differs from the catalogue by a fade or a couple of seconds of
    /// silence, narrow enough that a radio edit and an eight-minute club mix
    /// stay two different songs.
    private static let durationSlack: TimeInterval = 15

    public init(tracks: [Track]) {
        for track in tracks where !track.isDeleted && !track.isUnresolvableShare {
            byKey[Self.key(title: track.title, artistName: track.artistName), default: []]
                .append(track)
        }
    }

    /// The library's copy of this song, if it has one.
    ///
    /// `duration` may be 0 for a snapshot that didn't carry one, in which case
    /// the name match stands on its own.
    public func match(title: String, artistName: String, duration: TimeInterval) -> Track? {
        let candidates = byKey[Self.key(title: title, artistName: artistName)] ?? []
        guard !candidates.isEmpty else { return nil }
        guard duration > 0 else { return candidates.first }

        return candidates
            .filter { $0.duration <= 0 || abs($0.duration - duration) <= Self.durationSlack }
            .min { abs($0.duration - duration) < abs($1.duration - duration) }
    }

    /// Adds a row written during the import that is using this index, so a
    /// playlist listing the same song twice under two spellings still lands in
    /// the library once.
    public mutating func insert(_ track: Track) {
        byKey[Self.key(title: track.title, artistName: track.artistName), default: []]
            .append(track)
    }

    // MARK: - Identity

    public static func key(title: String, artistName: String) -> String {
        normalisedTitle(title) + "|" + normalisedArtist(artistName)
    }

    /// The act a song is filed under, and only that one.
    ///
    /// Matching on the whole credit would miss the common case outright:
    /// catalogues disagree about whether the guests belong in the artist field
    /// or the title, so "A" and "A, B" have to be able to meet.
    private static func normalisedArtist(_ raw: String) -> String {
        fold(ImportService.creditedArtists(from: raw).first ?? raw)
    }

    /// Drops the parts of a title that describe the *pressing* rather than the
    /// song — the guest credit and the remaster stamp — then folds what's left.
    /// Anything else that distinguishes one recording from another (Live,
    /// Acoustic, Extended Mix) is deliberately kept.
    private static func normalisedTitle(_ raw: String) -> String {
        // The three passes below are regex replacements, and running them over
        // every title in the library is most of what an index costs to build —
        // enough to be felt on the main actor when a save asks for one.
        //
        // The overwhelming majority of titles contain none of the words these
        // patterns look for, and for those the answer is `fold(raw)` with no
        // matching at all. So the words are checked for first, with a plain
        // case-insensitive substring search, and the regexes run only on the
        // small minority of titles that could possibly match one.
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

    /// Whether a title mentions the pressing at all — a guest credit, a
    /// remaster, a mono/stereo stamp.
    ///
    /// Deliberately over-inclusive: every string any of the three patterns
    /// could match contains one of these, so a false positive costs one wasted
    /// regex pass and a false negative is impossible. "ft" is checked bare
    /// because it appears as both "ft." and "ft ", and a title containing the
    /// letters incidentally ("Left Alone") only pays the pass it would have
    /// paid before this existed.
    private static let pressingMarkers = ["feat", "ft", "w/", "remaster", "mono", "stereo"]

    private static func containsPressingMarker(_ raw: String) -> Bool {
        pressingMarkers.contains { raw.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Case, accents and punctuation carry no identity here — "Déjà Vu",
    /// "Deja Vu" and "deja-vu" are one song under three spellings.
    private static func fold(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let stripped = String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return stripped.split(separator: " ").joined(separator: " ")
    }
}
