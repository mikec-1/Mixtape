// MetadataEnrichmentService.swift
// Mixtape — Core/Services/Enrichment
//
// Orchestrates the metadata enrichment pipeline:
//
//   1. Check whether enrichment is warranted (missing artist/album/artwork/year)
//   2. Parse the filename for title + artist hints
//   3. Build the best possible iTunes query from filename hints + existing partial tags
//   4. Fetch and score iTunes results  (word-overlap similarity, title-weighted)
//   5. Return the top EnrichmentCandidate, or a filename-only fallback
//
// This service is stateless and Sendable — safe to share across concurrency domains.

import Foundation

public final class MetadataEnrichmentService: Sendable {

    // Minimum composite score to present an iTunes result to the user
    private static let minConfidence: Double = 0.25

    private let filenameParser: FilenameParser
    private let itunesClient:   ITunesSearchClient

    public init() {
        self.filenameParser = FilenameParser()
        self.itunesClient   = ITunesSearchClient()
    }

    // MARK: - Public API

    /// Whether an iTunes lookup could still add anything to `meta`.
    ///
    /// Import asks before deciding whether the review sheet has a lookup to
    /// run, so a fully-tagged file never sets one going.
    public func canImprove(_ meta: ParsedMetadata) -> Bool { needsEnrichment(meta) }

    /// The best candidate available without touching the network — embedded
    /// tags where the file has them, the filename reading where it doesn't.
    ///
    /// This is what the review sheet opens with, immediately, while `enrich`
    /// runs behind it. It is deliberately the same shape as the answer: if the
    /// lookup finds nothing, or the user is offline, what's already on screen
    /// is the final answer and nothing has to change.
    public func localCandidate(url: URL, existing: ParsedMetadata) -> EnrichmentCandidate {
        // A file with real tags: they're better evidence than its name.
        guard needsEnrichment(existing) else {
            return EnrichmentCandidate(
                title:       existing.title,
                artistName:  existing.artistName != "Unknown Artist" ? existing.artistName : nil,
                albumTitle:  existing.albumTitle != "Unknown Album"  ? existing.albumTitle : nil,
                year:        existing.year,
                genre:       existing.genre,
                trackNumber: existing.trackNumber,
                confidence:  1.0,
                source:      .existingMetadata
            )
        }

        let parsed           = filenameParser.parse(url)
        let filenameStem     = url.deletingPathExtension().lastPathComponent
        let hasEmbeddedTitle = existing.title != filenameStem && !existing.title.isEmpty
        let hasEmbeddedArtist = existing.artistName != "Unknown Artist"

        let title: String = hasEmbeddedTitle ? existing.title : (parsed.title ?? existing.title)

        return EnrichmentCandidate(
            title:       title,
            artistName:  hasEmbeddedArtist ? existing.artistName : parsed.artistName,
            albumTitle:  existing.albumTitle != "Unknown Album" ? existing.albumTitle : nil,
            year:        existing.year,
            genre:       existing.genre,
            trackNumber: parsed.trackNumber ?? existing.trackNumber,
            confidence:  0.1,
            source:      .filenameOnly
        )
    }

    /// Returns an `EnrichmentCandidate` when the track is missing metadata or artwork,
    /// or `nil` when everything already looks complete.
    public func enrich(url: URL, existing: ParsedMetadata) async -> EnrichmentCandidate? {
        guard needsEnrichment(existing) else { return nil }

        // 1. Filename hints
        let parsed = filenameParser.parse(url)
        let filenameStem = url.deletingPathExtension().lastPathComponent

        // 2. Best query inputs:
        //    Prefer embedded tag if it differs from the raw filename stem (i.e. the parser
        //    found a real tag), otherwise fall through to the filename parse result.
        let hasEmbeddedTitle  = existing.title != filenameStem && !existing.title.isEmpty
        let hasEmbeddedArtist = existing.artistName != "Unknown Artist"

        let rawQueryTitle: String? = hasEmbeddedTitle ? existing.title : parsed.title
        let queryArtist:   String? = hasEmbeddedArtist ? existing.artistName : parsed.artistName

        // Strip version modifiers (slowed, sped up, reverb, nightcore, remix, etc.)
        // so the iTunes search targets the canonical song name.
        let queryTitle: String? = rawQueryTitle.map { filenameParser.stripVersionModifiers($0) }

        // 3. Without at least a title guess we can't do anything useful
        guard let queryTitle, let rawQueryTitle else {
            return parsed.title.map {
                EnrichmentCandidate(title: $0,
                                    artistName: queryArtist,
                                    trackNumber: parsed.trackNumber,
                                    confidence: 0.1,
                                    source: .filenameOnly)
            }
        }

        let primary = Reading(rawTitle: rawQueryTitle,
                              searchTitle: queryTitle,
                              artist: queryArtist)

        // "Artist - Title" is what the parser assumes, but "Title - Artist" is
        // just as common in the wild and the two are indistinguishable from the
        // string alone — which is how a Tate McRae song arrives at the review
        // sheet filed as an artist called "Get What I Want".
        //
        // Only worth asking when both halves came from the filename. Real
        // embedded tags say which is which, and swapping those would be
        // inventing a problem the file doesn't have.
        let alternate: Reading? = {
            guard !hasEmbeddedTitle, !hasEmbeddedArtist,
                  let flippedTitle = parsed.artistName,
                  let flippedArtist = parsed.title
            else { return nil }
            return Reading(rawTitle: flippedTitle,
                           searchTitle: filenameParser.stripVersionModifiers(flippedTitle),
                           artist: flippedArtist)
        }()

        // 4. Query iTunes — fall back gracefully if network is unavailable
        var reading = primary
        let scoredBest: (ITunesTrackResult, Double)?
        do {
            if let hit = try await bestMatch(for: primary) {
                scoredBest = hit
            } else if let alternate, let hit = try await bestMatch(for: alternate) {
                // The catalogue recognised the other reading and not this one,
                // and — because both gates ran — it recognised the *pair*, not
                // just a song that happens to share the name. That's the only
                // evidence available about which half of the filename is which.
                print("[Enrichment] Swapped reading matched — filename was 'Title - Artist'")
                scoredBest = hit
                reading    = alternate
            } else {
                scoredBest = nil
            }
        } catch {
            print("[Enrichment] iTunes query failed: \(error.localizedDescription)")
            return EnrichmentCandidate(title: primary.rawTitle,
                                       artistName: primary.artist,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 5. No confident iTunes match — return filename-only candidate with
        //    the original title. Neither reading was recognised, so there is no
        //    reason to prefer the flipped one; the parser's assumption stands.
        guard let (best, confidence) = scoredBest else {
            print("[Enrichment] No result above threshold \(Self.minConfidence) — using filename only")
            // Use the RAW (un-stripped) title so the track keeps its original name
            return EnrichmentCandidate(title: primary.rawTitle,
                                       artistName: primary.artist,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 6. Good iTunes match found.
        //     Keep the user's ORIGINAL title (e.g. "Mist slowed") — it accurately
        //     describes their file. Pull everything else (artist, album, artwork,
        //     year, genre) from iTunes.
        //     Fetch the Deezer artist profile photo in parallel.
        let originalTitle = reading.rawTitle
        let artworkURL = best.artworkUrl100
            .flatMap { itunesClient.artworkURL(from: $0, size: 600) }

        // Primary artist name for the Deezer lookup (strip featured artists)
        let primaryArtist = ImportService.primaryArtistName(from: best.artistName)
        let artistImageURL = await itunesClient.artistImageURL(for: primaryArtist)
        print("[Enrichment] Deezer artist image for '\(primaryArtist)': \(artistImageURL?.absoluteString ?? "none")")

        return EnrichmentCandidate(
            title:          originalTitle,     // ← preserve "Mist slowed", not "Mist"
            artistName:     best.artistName,
            albumTitle:     best.collectionName,
            year:           best.releaseDate.flatMap { Int($0.prefix(4)) },
            genre:          best.primaryGenreName,
            trackNumber:    best.trackNumber ?? parsed.trackNumber,
            artworkURL:     artworkURL,
            artistImageURL: artistImageURL,
            confidence:     confidence,
            source:         .itunes
        )
    }

    // MARK: - Helpers

    /// One interpretation of which half of a filename is the song and which is
    /// the performer. `"A - B"` yields two of these, and only the catalogue can
    /// say which one is right.
    private struct Reading {
        /// Un-stripped — what the file says, and what stays on the track.
        let rawTitle:    String
        /// Version modifiers removed, for the catalogue query only.
        let searchTitle: String
        let artist:      String?
    }

    /// Searches iTunes for one reading and returns its best scoring result,
    /// or nil when nothing clears the identity gates and `minConfidence`.
    /// Throws only on network failure, which the caller treats differently
    /// from "no match".
    private func bestMatch(for reading: Reading) async throws -> (ITunesTrackResult, Double)? {
        let results = try await itunesClient.search(title: reading.searchTitle,
                                                    artist: reading.artist)
        print("[Enrichment] iTunes returned \(results.count) results for title='\(reading.searchTitle)' artist='\(reading.artist ?? "nil")'")

        // Pre-filter: exclude result types that clearly don't match the intent.
        // If the user's file isn't labelled "instrumental" or "karaoke", they don't
        // want those versions — even if they happen to share the same title.
        let queryLower = reading.searchTitle.lowercased()
        let queryIsInstrumental = queryLower.contains("instrumental") || queryLower.contains("karaoke")
        let filteredResults = results.filter { r in
            if queryIsInstrumental { return true }   // user wants that type — keep all
            let name = r.trackName.lowercased()
            return !name.contains("instrumental") &&
                   !name.contains("karaoke")      &&
                   !name.contains("tribute")      &&
                   !name.contains("made famous")
        }
        print("[Enrichment] After type-filter: \(filteredResults.count) / \(results.count) results remain")

        // Identity gates. Scoring alone can't do this job — it's a weighted
        // blend, so a perfect title drags a completely wrong artist over the
        // line at 0.65. That is how a Kanye West file came back as AURORA's
        // "Runaway", and how an unreleased Tate McRae song came back as a
        // Morgan Wallen collab. A near-miss is not a match; when nothing here
        // is genuinely the same song, the filename is the better answer.
        let plausible = filteredResults.filter { r in
            guard titlesDescribeSameSong(result: r.trackName, query: reading.searchTitle) else { return false }
            // Nothing to check against for a single-component filename — the
            // title is the only evidence the file offers.
            guard let artist = reading.artist else { return true }
            return artistsMatch(r.artistName, artist)
        }
        print("[Enrichment] After identity gates: \(plausible.count) / \(filteredResults.count) results remain")

        return plausible
            .map { r -> (ITunesTrackResult, Double) in
                let s = score(result: r,
                              queryTitle: reading.searchTitle,
                              queryArtist: reading.artist)
                print("[Enrichment]   \(String(format: "%.2f", s)) '\(r.trackName)' by '\(r.artistName)'")
                return (r, s)
            }
            .filter { $0.1 >= Self.minConfidence }
            .max { $0.1 < $1.1 }
    }

    // MARK: - Identity gates

    /// Is `result` the same song the file is named after?
    ///
    /// Extra words on the catalogue side are ordinary — "(feat. X)", a
    /// subtitle, an edition marker. Extra words on the *user's* side are the
    /// warning sign: the file says "Get What I Want", the nearest catalogue
    /// entry is "What I Want", and those are different songs by different
    /// people. Jaccard can't see that asymmetry — it scored that pair 0.75.
    private func titlesDescribeSameSong(result: String, query: String) -> Bool {
        let queryWords  = words(filenameParser.stripVersionModifiers(query))
        let resultWords = words(stripFeaturedGroup(filenameParser.stripVersionModifiers(result)))
        guard !queryWords.isEmpty, !resultWords.isEmpty else { return false }
        return queryWords.isSubset(of: resultWords)
    }

    /// Do these two artist names refer to the same act?
    ///
    /// Containment rather than similarity, because both directions are normal:
    /// the file says "Tyler" for "Tyler, The Creator", and the catalogue says
    /// "Morgan Wallen & Tate McRae" for a file credited to Tate McRae. What it
    /// rejects is the case that matters — no overlap at all.
    private func artistsMatch(_ result: String, _ query: String) -> Bool {
        let a = words(result), b = words(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.isSubset(of: b) || b.isSubset(of: a)
    }

    /// Drops a trailing "(feat. …)" group from a catalogue title. Bracketed
    /// forms only: a bare "with" is a word in plenty of real titles
    /// ("Dancing With Myself"), and cutting there compares half a song.
    private func stripFeaturedGroup(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]?\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Meaningful normalised words. One-character tokens are dropped — they're
    /// mostly apostrophe debris ("it's" → "it s") — unless that empties the set.
    private func words(_ s: String) -> Set<String> {
        let all = Set(normalize(s).components(separatedBy: " ").filter { !$0.isEmpty })
        let meaningful = all.filter { $0.count > 1 }
        return meaningful.isEmpty ? all : meaningful
    }

    /// Enrichment is warranted when any key field is missing.
    private func needsEnrichment(_ meta: ParsedMetadata) -> Bool {
        meta.artistName == "Unknown Artist" ||
        meta.albumTitle == "Unknown Album"  ||
        meta.artworkData == nil             ||
        meta.year        == nil
    }

    /// Composite confidence score for an iTunes result against the query.
    /// Title is weighted 65%, artist 35%.
    ///
    /// Both sides are stripped of version modifiers before comparison so that
    /// "Blinding Lights" (iTunes) scores well against "Blinding Lights" (stripped query).
    private func score(result: ITunesTrackResult,
                       queryTitle: String,
                       queryArtist: String?) -> Double {
        let cleanResult = filenameParser.stripVersionModifiers(result.trackName)
        let cleanQuery  = filenameParser.stripVersionModifiers(queryTitle)
        let titleScore  = similarity(cleanResult, cleanQuery)
        let artistScore = queryArtist.map { similarity(result.artistName, $0) } ?? 0.5
        return titleScore * 0.65 + artistScore * 0.35
    }

    /// Jaccard word-overlap similarity after normalisation.
    private func similarity(_ a: String, _ b: String) -> Double {
        let a = normalize(a)
        let b = normalize(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1.0 }
        let wordsA = Set(a.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let wordsB = Set(b.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let intersection = Double(wordsA.intersection(wordsB).count)
        let union        = Double(wordsA.union(wordsB).count)
        return union > 0 ? intersection / union : 0
    }

    /// Lowercase, strip punctuation, collapse whitespace.
    private func normalize(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: .punctuationCharacters).joined(separator: " ")
         .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
