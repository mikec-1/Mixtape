// ITunesSearchClient.swift
// Mixtape — Core/Services/Enrichment
//
// Thin async wrapper around the public iTunes Search + Lookup APIs.
// No API key required.
//
// Search strategy (when artist is known):
//   1. Find the artist's iTunes ID via entity=musicArtist search
//   2. Look up ALL their songs via /lookup?id=artistId&entity=song
//   3. Score those songs against the stripped title → guaranteed correct artist
//   + Title-only search runs in parallel as a fallback for title matches
//     when no artist is known or artist lookup fails.
//
// Artwork URL trick: swap "100x100bb" → "600x600bb" in artworkUrl100.

import Foundation
// MARK: - Public result model

public struct ITunesTrackResult: Decodable, Sendable {
    public let trackName:        String
    public let artistName:       String
    public let collectionName:   String?
    public let artworkUrl100:    String?
    public let releaseDate:      String?    // "2014-07-01T07:00:00Z"
    public let trackNumber:      Int?
    public let primaryGenreName: String?
}

// MARK: - Deezer response models (artist image lookup)

private struct DeezerArtistResponse: Decodable {
    let data: [DeezerArtist]
}

private struct DeezerArtist: Decodable {
    let name:           String
    let picture_xl:     String?
    let picture_medium: String?
}

// MARK: - Private response models

private struct SearchResponse: Decodable {
    let resultCount: Int
    let results:     [ITunesTrackResult]
}

private struct ArtistItem: Decodable {
    let artistId:   Int
    let artistName: String
}

private struct ArtistSearchResponse: Decodable {
    let resultCount: Int
    let results:     [ArtistItem]
}

/// Flexible item used for Lookup API responses which mix artist + track records.
private struct LookupItem: Decodable, Sendable {
    let wrapperType:      String
    let trackName:        String?
    let artistName:       String?
    let collectionName:   String?
    let artworkUrl100:    String?
    let releaseDate:      String?
    let trackNumber:      Int?
    let primaryGenreName: String?
}

private struct LookupResponse: Decodable, Sendable {
    let resultCount: Int
    let results:     [LookupItem]
}

/// Converts a raw lookup item to a track result.
/// Free function (not a method/property) to avoid Swift 6 actor-isolation inference.
private func trackResult(from item: LookupItem) -> ITunesTrackResult? {
    guard item.wrapperType == "track",
          let trackName  = item.trackName,
          let artistName = item.artistName else { return nil }
    return ITunesTrackResult(
        trackName:        trackName,
        artistName:       artistName,
        collectionName:   item.collectionName,
        artworkUrl100:    item.artworkUrl100,
        releaseDate:      item.releaseDate,
        trackNumber:      item.trackNumber,
        primaryGenreName: item.primaryGenreName
    )
}

// MARK: - Client

public final class ITunesSearchClient: Sendable {

    private static let searchURL = "https://itunes.apple.com/search"
    private static let lookupURL = "https://itunes.apple.com/lookup"

    public init() {}

    // MARK: - Public API

    /// Search for songs matching `title`, optionally scoped to `artist`.
    ///
    /// When `artist` is supplied the pipeline is:
    ///   • Find artist ID (entity=musicArtist) across GB→US→AU→CA storefronts
    ///   • Fetch their full song catalogue via Lookup API
    ///   • Merge with a parallel title-only search for extra coverage
    ///
    /// When no artist is supplied, falls back to title-only search.
    public func search(title: String, artist: String?) async throws -> [ITunesTrackResult] {
        var all: [ITunesTrackResult] = []

        // Run title search and artist-catalogue lookup concurrently
        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            group.addTask { (try? await self.searchByTitle(title)) ?? [] }
            if let artist {
                group.addTask { (try? await self.searchByArtistCatalogue(artist)) ?? [] }
            }
            for try await results in group { all.append(contentsOf: results) }
        }

        // Dedup by trackName + artistName (case-insensitive)
        var seen = Set<String>()
        return all.filter { r in
            let key = "\(r.trackName.lowercased())|\(r.artistName.lowercased())"
            return seen.insert(key).inserted
        }
    }

    // MARK: - Artwork helper

    /// Transforms Apple's 100×100 artwork URL to a higher resolution.
    public func artworkURL(from url100: String, size: Int = 600) -> URL? {
        URL(string: url100.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb"))
    }

    // MARK: - Deezer artist image

    /// Fetches the artist profile photo URL from Deezer (no API key required).
    /// Returns the XL (1000×1000) image, falling back to medium (250×250).
    public func artistImageURL(for artistName: String) async -> URL? {
        guard let encoded = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=1")
        else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(DeezerArtistResponse.self, from: data)
            guard let artist = decoded.data.first else { return nil }
            let raw = artist.picture_xl ?? artist.picture_medium
            return raw.flatMap { URL(string: $0) }
        } catch {
            print("[Deezer] Artist image lookup failed for '\(artistName)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private: title-only search

    /// Full-text song search across all storefronts, results merged.
    private func searchByTitle(_ title: String) async throws -> [ITunesTrackResult]? {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        var all: [ITunesTrackResult] = []
        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            for country in ["us", "gb", "au", "ca"] {
                guard let url = URL(string: "\(Self.searchURL)?term=\(encoded)&media=music&entity=song&limit=25&country=\(country)")
                else { continue }
                group.addTask {
                    guard let results = try? await self.fetchSearchResults(from: url)
                    else { return [] }
                    return results
                }
            }
            for try await results in group { all.append(contentsOf: results) }
        }

        let unique = deduplicated(all)
        print("[iTunes] title='\(title)' → \(unique.count) songs (text search)")
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private: artist-catalogue lookup

    /// Find artist ID then fetch their full song catalogue via Lookup API.
    /// This is the most reliable method — avoids the noise of general text search.
    private func searchByArtistCatalogue(_ artist: String) async throws -> [ITunesTrackResult]? {
        guard let artistId = try await findArtistId(artist) else {
            print("[iTunes] No artist ID found for '\(artist)'")
            return nil
        }
        print("[iTunes] Artist '\(artist)' → ID \(artistId)")
        return try await lookupSongs(artistId: artistId)
    }

    /// Search iTunes for an artist by name and return the best-matching artistId.
    /// Tries GB first (better for non-US artists), then US, AU, CA.
    private func findArtistId(_ artist: String) async throws -> Int? {
        guard let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        for country in ["gb", "us", "au", "ca"] {
            guard let url = URL(string: "\(Self.searchURL)?term=\(encoded)&entity=musicArtist&limit=5&country=\(country)")
            else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            guard let decoded = try? JSONDecoder().decode(ArtistSearchResponse.self, from: data),
                  let first = decoded.results.first else { continue }
            print("[iTunes] Found artist '\(first.artistName)' id=\(first.artistId) in \(country) store")
            return first.artistId
        }
        return nil
    }

    /// Fetch all songs for a given artistId via the Lookup API.
    /// Returns up to 200 songs; tries GB first for regional availability.
    private func lookupSongs(artistId: Int) async throws -> [ITunesTrackResult]? {
        var all: [ITunesTrackResult] = []

        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            for country in ["gb", "us", "au", "ca"] {
                guard let url = URL(string: "\(Self.lookupURL)?id=\(artistId)&entity=song&limit=200&country=\(country)")
                else { continue }
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                    guard let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data)
                    else { return [] }
                    return decoded.results.compactMap { trackResult(from: $0) }
                }
            }
            for try await results in group { all.append(contentsOf: results) }
        }

        let unique = deduplicated(all)
        print("[iTunes] Lookup artistId=\(artistId) → \(unique.count) songs across storefronts")
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private helpers

    private func fetchSearchResults(from url: URL) async throws -> [ITunesTrackResult] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(SearchResponse.self, from: data))?.results ?? []
    }

    private func deduplicated(_ results: [ITunesTrackResult]) -> [ITunesTrackResult] {
        var seen = Set<String>()
        return results.filter { r in
            let key = "\(r.trackName.lowercased())|\(r.artistName.lowercased())"
            return seen.insert(key).inserted
        }
    }
}
