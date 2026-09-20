// MixGenerator.swift
// Mixtape — Core/Services/Online
//
// Builds a playlist to order: pick a vibe, say how much of it should come out
// of the library you already have, and get a list back.
//
// This is a different job from `RecommendationEngine`, which answers "what
// should the landing page show this week" on its own schedule. Here the user
// has asked for one specific thing, once, and the two knobs they turned —
// which vibe, and how much of it is theirs already — are the whole brief.
//
// Every fetch fails soft. A vibe whose seeds don't resolve still produces a
// playlist, it is just more of the user's own music than they asked for; the
// result says so rather than pretending the split was honoured.

import Foundation

// MARK: - Vibes

/// One of the ready-made briefs on the generate sheet.
///
/// A vibe is described three ways because the two halves of a mix are found in
/// two different places: `seedArtists` and `queries` are what the catalogue is
/// asked for, `genres` and `seedArtists` are what the library is scored
/// against. Genre strings are matched loosely (`contains`), because a file's
/// genre tag is whatever the person who encoded it typed.
public struct MixVibe: Identifiable, Hashable, Sendable {

    public let id: String
    public let title: String
    /// The line under the title on the picker, and the playlist's description.
    public let blurb: String
    public let icon: String
    public let seedArtists: [String]
    public let genres: [String]
    public let queries: [String]

    /// The one vibe with no fixed brief: it reads the seeds out of the user's
    /// own listening instead. Handled in `generate`.
    public static let yourTaste = MixVibe(
        id: "taste",
        title: "Your Taste",
        blurb: "Built around whoever you have been playing lately",
        icon: "waveform",
        seedArtists: [],
        genres: [],
        queries: []
    )

    public static let presets: [MixVibe] = [
        yourTaste,
        MixVibe(id: "rock", title: "Rock", blurb: "Guitars, loud",
                icon: "guitars",
                seedArtists: ["Foo Fighters", "Arctic Monkeys", "Queens of the Stone Age",
                              "The Black Keys", "Nirvana"],
                genres: ["rock", "alternative", "grunge", "punk"],
                queries: ["rock anthems", "alt rock"]),

        MixVibe(id: "pop", title: "Pop", blurb: "Choruses you already know",
                icon: "star",
                seedArtists: ["Dua Lipa", "Harry Styles", "Ariana Grande",
                              "The Weeknd", "Charli XCX"],
                genres: ["pop", "dance pop", "synthpop"],
                queries: ["pop hits", "todays top hits"]),

        MixVibe(id: "whitegirl", title: "White Girl Music", blurb: "Taylor, Lana, Chappell, and the group chat",
                icon: "heart.text.square",
                seedArtists: ["Taylor Swift", "Lana Del Rey", "Chappell Roan",
                              "Gracie Abrams", "Sabrina Carpenter", "Olivia Rodrigo"],
                genres: ["pop", "indie pop", "singer-songwriter"],
                queries: ["sad girl pop", "pop girls"]),

        MixVibe(id: "hiphop", title: "Hip-Hop", blurb: "Rap, old and new",
                icon: "mic",
                seedArtists: ["Kendrick Lamar", "Drake", "Travis Scott",
                              "J. Cole", "Tyler, The Creator"],
                genres: ["hip hop", "hip-hop", "rap", "trap"],
                queries: ["rap caviar", "hip hop hits"]),

        MixVibe(id: "rnb", title: "R&B", blurb: "Smooth, late, slow",
                icon: "moon.stars",
                seedArtists: ["SZA", "Frank Ocean", "Daniel Caesar",
                              "Summer Walker", "Brent Faiyaz"],
                genres: ["r&b", "rnb", "soul", "neo soul"],
                queries: ["rnb", "soul classics"]),

        MixVibe(id: "electronic", title: "Electronic", blurb: "Four to the floor",
                icon: "waveform.path",
                seedArtists: ["Fred again..", "Disclosure", "Bicep",
                              "Daft Punk", "Jamie xx"],
                genres: ["electronic", "house", "techno", "dance", "edm"],
                queries: ["house music", "dance floor"]),

        MixVibe(id: "indie", title: "Indie", blurb: "Small rooms, big feelings",
                icon: "sparkles",
                seedArtists: ["Phoebe Bridgers", "Beabadoobee", "Mac DeMarco",
                              "boygenius", "Alvvays"],
                genres: ["indie", "indie rock", "indie pop", "bedroom pop"],
                queries: ["indie chill", "bedroom pop"]),

        MixVibe(id: "country", title: "Country", blurb: "Trucks optional",
                icon: "hat.cap",
                seedArtists: ["Zach Bryan", "Morgan Wallen", "Chris Stapleton",
                              "Kacey Musgraves", "Luke Combs"],
                genres: ["country", "americana", "folk"],
                queries: ["country hits", "americana"]),

        MixVibe(id: "metal", title: "Metal", blurb: "Heavier than the rest of this list",
                icon: "flame",
                seedArtists: ["Metallica", "Gojira", "Bring Me The Horizon",
                              "Slipknot", "Sleep Token"],
                genres: ["metal", "metalcore", "hardcore", "heavy metal"],
                queries: ["metal essentials", "metalcore"]),

        MixVibe(id: "jazz", title: "Jazz", blurb: "Brushes, upright bass, a room somewhere",
                icon: "pianokeys",
                seedArtists: ["Miles Davis", "John Coltrane", "Bill Evans",
                              "Nubya Garcia", "Robert Glasper"],
                genres: ["jazz", "bebop", "fusion"],
                queries: ["jazz classics", "late night jazz"]),

        MixVibe(id: "latin", title: "Latin", blurb: "Reggaetón and everything around it",
                icon: "flame.circle",
                seedArtists: ["Bad Bunny", "Karol G", "Rosalía",
                              "Feid", "Peso Pluma"],
                genres: ["latin", "reggaeton", "latin pop"],
                queries: ["reggaeton", "latin hits"]),

        MixVibe(id: "focus", title: "Focus", blurb: "Nothing that asks for your attention",
                icon: "brain.head.profile",
                seedArtists: ["Nils Frahm", "Ólafur Arnalds", "Tycho",
                              "Bonobo", "Nujabes"],
                genres: ["ambient", "instrumental", "classical", "lo-fi", "lofi"],
                queries: ["deep focus", "lofi beats"]),

        MixVibe(id: "party", title: "Party", blurb: "For a room with the lights off",
                icon: "party.popper",
                seedArtists: ["Calvin Harris", "David Guetta", "Doja Cat",
                              "Lady Gaga", "Rihanna"],
                genres: ["dance", "pop", "house", "party"],
                queries: ["party bangers", "dance party"]),
    ]
}

// MARK: - Result

/// What a generation produced, before anything is written to the library.
public struct GeneratedMix: Sendable {
    public let name: String
    public let description: String
    /// Songs pulled from what the user already owns, in play order.
    public let libraryTrackIDs: [UUID]
    /// Songs from the catalogue that will be saved alongside them.
    public let onlineTracks: [OnlineTrack]
    public let covers: [URL]

    public var isEmpty: Bool { libraryTrackIDs.isEmpty && onlineTracks.isEmpty }
    public var total: Int { libraryTrackIDs.count + onlineTracks.count }
}

// MARK: - Generator

public enum MixGenerator {

    /// The band the slider moves in. Nobody wants a 400-song generated mix, and
    /// under a dozen it is a row rather than a playlist.
    public static let countRange: ClosedRange<Int> = 12...60
    public static let defaultCount = 25

    /// Build a mix to the given brief.
    ///
    /// `libraryShare` is the fraction that should come from the user's own
    /// library, 0…1 — the slider, straight through. It is a target, not a
    /// promise: a library with four rock songs in it cannot fill a 50% rock
    /// mix, and the shortfall is taken from the catalogue rather than left as
    /// a hole. The reverse holds too, offline.
    @MainActor
    public static func generate(vibe: MixVibe,
                                libraryShare: Double,
                                count: Int,
                                library: LibraryService,
                                stats: ListeningStatsService,
                                catalog: ITunesSearchClient) async -> GeneratedMix {

        let count  = min(max(count, countRange.lowerBound), countRange.upperBound)
        let share  = min(max(libraryShare, 0), 1)
        let wanted = Int((Double(count) * share).rounded())

        // A taste mix has no fixed seeds — the listening history is the brief.
        let seeds = vibe.id == MixVibe.yourTaste.id
            ? RecommendationEngine.seeds(stats: stats, library: library, limit: 5)
            : vibe.seedArtists

        let known    = RecommendationEngine.knownKeys(library: library)
        let picked   = libraryPicks(vibe: vibe, seeds: seeds, limit: wanted,
                                    library: library, stats: stats)
        // Ask for more than the gap so a short shortfall in the library can
        // still be covered, and so the dedupe below has something to cut.
        let needed   = count - picked.count
        let online   = needed > 0
            ? await cataloguePicks(vibe: vibe, seeds: seeds, limit: needed,
                                   known: known, catalog: catalog)
            : []

        let name = vibe.id == MixVibe.yourTaste.id ? "Your Mix" : "\(vibe.title) Mix"
        return GeneratedMix(
            name: name,
            description: description(vibe: vibe,
                                     fromLibrary: picked.count,
                                     fromCatalogue: online.count),
            libraryTrackIDs: picked.map(\.id),
            onlineTracks: online,
            covers: Array(online.compactMap(\.artworkURL).prefix(4))
        )
    }

    /// Says what actually happened rather than what was asked for — a mix that
    /// came out 90% library because the network was down should read that way
    /// on the playlist it produced.
    private static func description(vibe: MixVibe,
                                    fromLibrary: Int,
                                    fromCatalogue: Int) -> String {
        switch (fromLibrary, fromCatalogue) {
        case (0, _):  return "\(vibe.blurb). All new to you."
        case (_, 0):  return "\(vibe.blurb). All from your library."
        default:      return "\(vibe.blurb). \(fromLibrary) from your library, \(fromCatalogue) new."
        }
    }

    // MARK: The library half

    /// The user's own songs that fit the brief, best fit first.
    ///
    /// Scored rather than filtered: a hard genre filter returns nothing at all
    /// for a library whose files were tagged by three different rippers, and
    /// "nothing at all" is the one answer a generator must never give.
    @MainActor
    private static func libraryPicks(vibe: MixVibe,
                                     seeds: [String],
                                     limit: Int,
                                     library: LibraryService,
                                     stats: ListeningStatsService) -> [Track] {
        guard limit > 0 else { return [] }

        let seedNames = Set(seeds.map { $0.lowercased() })
        let plays = Dictionary(
            stats.compute(period: .allTime).topArtists.map { ($0.name.lowercased(), $0.playCount) },
            uniquingKeysWith: max
        )

        func score(_ track: Track) -> Int {
            var score = 0
            let artist = track.artistName.lowercased()
            if seedNames.contains(artist) { score += 60 }
            if let genre = track.genre?.lowercased(),
               vibe.genres.contains(where: { genre.contains($0) }) { score += 40 }
            // A tie-break, not a ranking of its own: within the songs that fit,
            // prefer the artists this person actually plays.
            score += min(plays[artist] ?? 0, 20)
            return score
        }

        // Spelled out in steps rather than chained: the tuple-returning `map`
        // in the middle of a chain is more than the type checker will sit
        // through in reasonable time.
        let living: [Track] = library.tracks.filter { !$0.isDeleted }
        var scored: [ScoredTrack] = living.map { ScoredTrack(track: $0, score: score($0)) }
        scored.sort { a, b in
            a.score == b.score ? a.track.title < b.track.title : a.score > b.score
        }

        // A vibe with a real brief takes only songs that matched it. Falling
        // back to unmatched ones would quietly turn "Jazz Mix" into "25 songs".
        // `.yourTaste` has no brief to miss, so everything counts.
        let eligible = vibe.id == MixVibe.yourTaste.id
            ? scored
            : scored.filter { $0.score > 20 }

        // Shuffled within the take so two runs of the same brief aren't the
        // same playlist, then cut to size.
        var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970))
        let take: [Track] = eligible.prefix(limit * 3).map { $0.track }
        return Array(take.shuffled(using: &rng).prefix(limit))
    }

    /// A track and how well it fits the brief.
    private struct ScoredTrack {
        let track: Track
        let score: Int
    }

    // MARK: The catalogue half

    /// New songs for the brief, excluding anything already in the library —
    /// half the point of the slider is that the other half is *new*.
    private static func cataloguePicks(vibe: MixVibe,
                                       seeds: [String],
                                       limit: Int,
                                       known: Set<String>,
                                       catalog: ITunesSearchClient) async -> [OnlineTrack] {
        guard limit > 0 else { return [] }

        let pool: [OnlineTrack] = await withTaskGroup(of: [OnlineTrack].self) { group in
            for name in seeds.prefix(5) {
                group.addTask {
                    guard let artist = await catalog.searchArtists(query: name, limit: 1).first
                    else { return [] }
                    return await catalog.radioTracks(artistId: artist.id, limit: 25)
                }
            }
            for query in vibe.queries.prefix(2) {
                group.addTask {
                    await catalog.searchPopular(query: query, limit: 30)
                        .map(Self.online)
                }
            }
            var out: [OnlineTrack] = []
            for await batch in group { out.append(contentsOf: batch) }
            return out
        }

        var seen = Set<String>()
        var unique: [OnlineTrack] = []
        for track in pool {
            let key = normalize(track.title) + "|" + normalize(track.artistName)
            guard !known.contains(key), seen.insert(key).inserted else { continue }
            unique.append(track)
        }

        var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970) &+ 1)
        return Array(unique.shuffled(using: &rng).prefix(limit))
    }

    /// A catalogue search hit as a playable row. `searchPopular` answers with
    /// the enrichment shape; everything downstream of a generated mix — saving
    /// it, playing it — speaks `OnlineTrack`.
    private static func online(_ hit: ITunesTrackResult) -> OnlineTrack {
        OnlineTrack(title: hit.trackName,
                    artistName: hit.artistName,
                    albumTitle: hit.collectionName ?? "",
                    duration: Double(hit.trackTimeMillis ?? 0) / 1000,
                    artworkURL: hit.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "600x600")) },
                    sourceID: hit.sourceID,
                    isExplicit: hit.isExplicit)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
