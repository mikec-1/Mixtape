// Metadata enrichment pipeline:
// 1. Check whether enrichment is needed (missing artist/album/artwork/year)
// 2. Parse the filename for title + artist hints
// 3. Build an iTunes query from those hints and partial tags
// 4. Fetch and score iTunes results (title-weighted word overlap)
// 5. Return the best EnrichmentCandidate, or a filename-only fallback
// Stateless and Sendable.

import Foundation
import OSLog

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

    /// Whether an iTunes lookup could add anything, so fully tagged files skip it.
    public func canImprove(_ meta: ParsedMetadata) -> Bool { needsEnrichment(meta) }

    /// Best candidate without the network: embedded tags, else the filename. The review sheet
    /// shows this while `enrich` runs, so offline or no-match results need no change.
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

    /// A candidate when metadata or artwork is missing, nil when complete.
    public func enrich(url: URL, existing: ParsedMetadata) async -> EnrichmentCandidate? {
        guard needsEnrichment(existing) else { return nil }

        // 1. Filename hints
        let parsed = filenameParser.parse(url)
        let filenameStem = url.deletingPathExtension().lastPathComponent

        // 2. Prefer a real embedded tag (differs from the filename stem), else the filename parse.
        let hasEmbeddedTitle  = existing.title != filenameStem && !existing.title.isEmpty
        let hasEmbeddedArtist = existing.artistName != "Unknown Artist"

        let rawQueryTitle: String? = hasEmbeddedTitle ? existing.title : parsed.title
        let queryArtist:   String? = hasEmbeddedArtist ? existing.artistName : parsed.artistName

        // Strip version modifiers (slowed, sped up, remix...) to search for the original song.
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

        // "Title - Artist" is as common as "Artist - Title", so also try the flipped reading.
        // Only when both halves came from the filename.
        let alternate: Reading? = {
            guard !hasEmbeddedTitle, !hasEmbeddedArtist,
                  let flippedTitle = parsed.artistName,
                  let flippedArtist = parsed.title
            else { return nil }
            return Reading(rawTitle: flippedTitle,
                           searchTitle: filenameParser.stripVersionModifiers(flippedTitle),
                           artist: flippedArtist)
        }()

        // 4. Query iTunes, falling back if offline.
        var reading = primary
        let scoredBest: (ITunesTrackResult, Double)?
        do {
            if let hit = try await bestMatch(for: primary) {
                scoredBest = hit
            } else if let alternate, let hit = try await bestMatch(for: alternate) {
                // The catalogue matched the flipped pair and not the original.
                MixLog.importing.debug("[Enrichment] Swapped reading matched, filename was 'Title - Artist'")
                scoredBest = hit
                reading    = alternate
            } else {
                scoredBest = nil
            }
        } catch {
            MixLog.importing.error("[Enrichment] iTunes query failed: \(error.localizedDescription)")
            return EnrichmentCandidate(title: primary.rawTitle,
                                       artistName: primary.artist,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 5. No confident match: filename-only candidate, keeping the parser's reading.
        guard let (best, confidence) = scoredBest else {
            MixLog.importing.debug("[Enrichment] No result above threshold \(Self.minConfidence), using filename only")
            // Use the RAW (un-stripped) title so the track keeps its original name
            return EnrichmentCandidate(title: primary.rawTitle,
                                       artistName: primary.artist,
                                       trackNumber: parsed.trackNumber,
                                       confidence: 0.1,
                                       source: .filenameOnly)
        }

        // 6. Match found. Keep the user's original title (e.g. "Mist slowed") and take the rest
        // from iTunes. The Deezer artist photo is fetched in parallel.
        let originalTitle = reading.rawTitle
        let artworkURL = best.artworkUrl100
            .flatMap { itunesClient.artworkURL(from: $0, size: 600) }

        // Primary artist name for the Deezer lookup (strip featured artists)
        let primaryArtist = ImportService.primaryArtistName(from: best.artistName)
        let artistImageURL = await itunesClient.artistImageURL(for: primaryArtist)
        MixLog.importing.debug("[Enrichment] Deezer artist image for '\(primaryArtist)': \(artistImageURL?.absoluteString ?? "none")")

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

    /// One reading of which half of "A - B" is the song and which the artist.
    private struct Reading {
        /// Un-stripped, as the file says. This stays on the track.
        let rawTitle:    String
        /// Version modifiers removed, for the catalogue query only.
        let searchTitle: String
        let artist:      String?
    }

    /// Best iTunes result for one reading that passes the identity gates and `minConfidence`.
    /// Throws only on network failure.
    private func bestMatch(for reading: Reading) async throws -> (ITunesTrackResult, Double)? {
        let results = try await itunesClient.search(title: reading.searchTitle,
                                                    artist: reading.artist)
        MixLog.importing.debug("[Enrichment] iTunes returned \(results.count) results for title='\(reading.searchTitle)' artist='\(reading.artist ?? "nil")'")

        // Drop instrumental/karaoke results unless the query asks for them.
        let queryLower = reading.searchTitle.lowercased()
        let queryIsInstrumental = queryLower.contains("instrumental") || queryLower.contains("karaoke")
        let filteredResults = results.filter { r in
            if queryIsInstrumental { return true }  // user wants that type, keep all
            let name = r.trackName.lowercased()
            return !name.contains("instrumental") &&
                   !name.contains("karaoke")      &&
                   !name.contains("tribute")      &&
                   !name.contains("made famous")
        }
        MixLog.importing.debug("[Enrichment] After type-filter: \(filteredResults.count) / \(results.count) results remain")

        // Identity gates. The weighted score lets a perfect title carry a wrong artist,
        // so both must independently match.
        let plausible = filteredResults.filter { r in
            guard titlesDescribeSameSong(result: r.trackName, query: reading.searchTitle) else { return false }
            // Single-component filename: the title is the only evidence.
            guard let artist = reading.artist else { return true }
            return artistsMatch(r.artistName, artist)
        }
        MixLog.importing.debug("[Enrichment] After identity gates: \(plausible.count) / \(filteredResults.count) results remain")

        return plausible
            .map { r -> (ITunesTrackResult, Double) in
                let s = score(result: r,
                              queryTitle: reading.searchTitle,
                              queryArtist: reading.artist)
                MixLog.importing.debug("[Enrichment]   \(String(format: "%.2f", s)) '\(r.trackName)' by '\(r.artistName)'")
                return (r, s)
            }
            .filter { $0.1 >= Self.minConfidence }
            .max { $0.1 < $1.1 }
    }

    // MARK: - Identity gates

    /// Extra words on the catalogue side ("(feat. X)", editions) are fine. Extra words on
    /// the file's side mean a different song ("Get What I Want" vs "What I Want").
    private func titlesDescribeSameSong(result: String, query: String) -> Bool {
        let queryWords  = words(filenameParser.stripVersionModifiers(query))
        let resultWords = words(stripFeaturedGroup(filenameParser.stripVersionModifiers(result)))
        guard !queryWords.isEmpty, !resultWords.isEmpty else { return false }
        return queryWords.isSubset(of: resultWords)
    }

    /// Containment either way ("Tyler" vs "Tyler, The Creator"). Rejects no overlap at all.
    private func artistsMatch(_ result: String, _ query: String) -> Bool {
        let a = words(result), b = words(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.isSubset(of: b) || b.isSubset(of: a)
    }

    /// Drops a trailing bracketed "(feat. ...)". Bare "with" is left since it appears in real titles.
    private func stripFeaturedGroup(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]?\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Normalised words. One-character tokens (apostrophe debris) are dropped unless that empties the set.
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

    /// Confidence for an iTunes result: title 65%, artist 35%. Both sides have version
    /// modifiers stripped first.
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
