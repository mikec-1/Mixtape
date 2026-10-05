// Artist photos and playlist covers for the profile page. Nothing a profile publishes
// carries an image, so they're resolved on the viewer's side: the local library first,
// then the catalogue lookups used elsewhere.

import Combine
import Foundation
import SwiftUI

// MARK: - Resolved artwork

/// Artwork as bytes (library) or a URL (catalogue).
enum ResolvedArtwork: Equatable, Sendable {
    case data(Data)
    case remote(URL)
}

// MARK: - Store

/// Resolves and caches images for one profile page. One store per page so artist lookups
/// batch into a single Spotify request.
@MainActor
final class ProfileArtworkStore: ObservableObject {

    /// Artist name (exactly as the stat spells it) -> photo.
    @Published private(set) var artistImages: [String: ResolvedArtwork] = [:]
    /// `shared_playlists` row id -> cover.
    @Published private(set) var playlistCovers: [UUID: ResolvedArtwork] = [:]

    /// The avatar's bytes, for the page's colour wash. `AvatarView` draws from the URL.
    @Published private(set) var avatar: Data?
    private var triedAvatar = false

    /// Hits and misses, so unknown names aren't looked up on every redraw.
    private var triedArtists:   Set<String> = []
    private var triedPlaylists: Set<UUID>   = []

    /// One request per cover, so cap how many fire on open.
    private static let coverLookupLimit = 12

    // MARK: Avatar

    /// Fetched once per page. Failure is final; the wash has a fallback colour.
    func resolveAvatar(_ url: URL?) async {
        guard !triedAvatar, let url else { return }
        triedAvatar = true

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty
        else { return }

        avatar = data
    }

    // MARK: Artists

    func resolveArtists(_ names: [String],
                        library: LibraryService,
                        spotify: SpotifyClient) async {
        let pending = names.filter { !triedArtists.contains($0) }
        guard !pending.isEmpty else { return }
        triedArtists.formUnion(pending)

        var unresolved: [String] = []
        for name in pending {
            if let data = library.artist(named: name)?.displayArtwork {
                artistImages[name] = .data(data)
            } else {
                unresolved.append(name)
            }
        }
        guard !unresolved.isEmpty else { return }

        // Stats record the full credit ("Drake feat. 21 Savage"), so credits that reduce to
        // the same artist share one lookup.
        var byQuery: [String: [String]] = [:]
        for name in unresolved {
            let query = ImportService.primaryArtistName(from: name)
            guard !query.isEmpty else { continue }
            byQuery[query, default: []].append(name)
        }
        guard !byQuery.isEmpty else { return }

        let urls = await spotify.artistImages(for: Array(byQuery.keys))
        for (query, credits) in byQuery {
            guard let url = urls[query] else { continue }
            for credit in credits { artistImages[credit] = .remote(url) }
        }
    }

    // MARK: Playlists

    func resolveCovers(_ summaries: [PublicPlaylistSummary],
                       library: LibraryService,
                       catalogue: ITunesSearchClient) async {
        var needsLookup: [PublicPlaylistSummary] = []

        // Best-first: the owner's own copy, then the published cover, then local guesses.
        for summary in summaries where !triedPlaylists.contains(summary.id) {
            triedPlaylists.insert(summary.id)
            if let data = library.playlist(id: summary.playlistID)?.displayArtwork {
                playlistCovers[summary.id] = .data(data)
            } else if let url = summary.artworkURL {
                playlistCovers[summary.id] = .remote(url)
            } else if let data = localTrackCover(for: summary, library: library) {
                playlistCovers[summary.id] = .data(data)
            } else if !summary.tracks.isEmpty {
                needsLookup.append(summary)
            }
        }
        guard !needsLookup.isEmpty else { return }

        let found = await withTaskGroup(of: (UUID, URL?).self) { group in
            for summary in needsLookup.prefix(Self.coverLookupLimit) {
                group.addTask { (summary.id, await Self.catalogueCover(for: summary, catalogue: catalogue)) }
            }
            var out: [UUID: URL] = [:]
            for await (id, url) in group {
                if let url { out[id] = url }
            }
            return out
        }
        for (id, url) in found { playlistCovers[id] = .remote(url) }
    }

    /// The album art of a song the viewer owns. Below the published cover.
    private func localTrackCover(for summary: PublicPlaylistSummary,
                                 library: LibraryService) -> Data? {
        summary.tracks.lazy.compactMap { library.track(id: $0.id)?.displayArtwork }.first
    }

    /// The first song's album art for a cover nobody published.
    private static func catalogueCover(for summary: PublicPlaylistSummary,
                                       catalogue: ITunesSearchClient) async -> URL? {
        guard let first = summary.tracks.first,
              let hit = try? await catalogue.search(title: first.title, artist: first.artist).first,
              let raw = hit.artworkUrl100
        else { return nil }
        return catalogue.artworkURL(from: raw, size: 600)
    }
}

// MARK: - View

/// Draws either artwork shape, or `placeholder` while loading or when there's nothing.
struct ProfileArtworkView<Placeholder: View>: View {

    let artwork: ResolvedArtwork?
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        switch artwork {
        case .data(let data):
            if let image = mixImage(from: data) {
                image.resizable().scaledToFill()
            } else {
                placeholder()
            }
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder()
                }
            }
        case nil:
            placeholder()
        }
    }
}
