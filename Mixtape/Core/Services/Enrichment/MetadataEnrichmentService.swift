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
        let rawQueryTitle: String? = {
            if existing.title != filenameStem, !existing.title.isEmpty { return existing.title }
            return parsed.title
        }()

        let queryArtist: String? = {
            if existing.artistName != "Unknown Artist" { return existing.artistName }
            return parsed.artistName
        }()

        // Strip version modifiers (slowed, sped up, reverb, nightcore, remix, etc.)
        // so the iTunes search targets the canonical song name.
        let queryTitle: String? = rawQueryTitle.map { filenameParser.stripVersionModifiers($0) }

        // 3. Without at least a title guess we can't do anything useful
        guard let queryTitle else {
            return parsed.title.map {
                EnrichmentCandidate(title: $0,
                                    artistName: parsed.artistName,
                                    trackNumber: parsed.trackNumber,
                                    confidence: 0.1,
                                    source: .filenameOnly)
            }
        }

        // 4. Query iTunes — fall back gracefully if network is unavailable
        let results: [ITunesTrackResult]
        do {
            results = try await itunesClient.search(title: queryTitle, artist: queryArtist)
            print("[Enrichment] iTunes returned \(results.count) results for title='\(queryTitle)' artist='\(queryArtist ?? "nil")'")
        } catch {
            print("[Enrichment] iTunes query failed: \(error.localizedDescription)")
            return EnrichmentCandidate(title: queryTitle,
                                       artistName: parsed.artistName,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 5. Pre-filter: exclude result types that clearly don't match the intent.
        //    If the user's file isn't labelled "instrumental" or "karaoke", they don't
        //    want those versions — even if they happen to share the same title.
        let queryLower = queryTitle.lowercased()
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

        // 6. Score remaining results
        let scored: [(ITunesTrackResult, Double)] = filteredResults
            .map { r -> (ITunesTrackResult, Double) in
                let s = score(result: r, queryTitle: queryTitle, queryArtist: queryArtist)
                print("[Enrichment]   \(String(format: "%.2f", s)) '\(r.trackName)' by '\(r.artistName)'")
                return (r, s)
            }
            .filter { $0.1 >= Self.minConfidence }
            .sorted { $0.1 > $1.1 }

        // 7a. No confident iTunes match — return filename-only candidate with original title
        guard let (best, confidence) = scored.first else {
            print("[Enrichment] No result above threshold \(Self.minConfidence) — using filename only")
            // Use the RAW (un-stripped) title so the track keeps its original name
            let originalTitle = rawQueryTitle ?? queryTitle
            return EnrichmentCandidate(title: originalTitle,
                                       artistName: parsed.artistName,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 7b. Good iTunes match found.
        //     Keep the user's ORIGINAL title (e.g. "Mist slowed") — it accurately
        //     describes their file. Pull everything else (artist, album, artwork,
        //     year, genre) from iTunes.
        //     Fetch the Deezer artist profile photo in parallel.
        let originalTitle = rawQueryTitle ?? best.trackName
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
