// ProfileArtwork.swift
// Mixtape — Features/Social
//
// Artist photos and playlist covers for the profile page.
//
// Nothing a profile publishes carries an image. `profile_stats.top_artists` is a
// name and a play count; `shared_playlists` has no artwork column at all, and
// couldn't usefully gain one as things stand — the `artwork` storage bucket is
// private and its policy keys on the owner's user id, so a visitor can't read
// the owner's cover even when told exactly where it is. The page drew a monogram
// and a grey square because that was genuinely all it had.
//
// So the pictures are resolved on the *viewer's* side, cheapest source first:
// whatever the local library already holds (free, and on your own profile it's
// precisely the right image), then the same catalogue lookups the rest of the
// app uses for artist photos and album art. Publishing real covers would take a
// migration and a storage-policy change; this takes neither.

import Combine
import Foundation
import SwiftUI

// MARK: - Resolved artwork

/// An image that arrived as bytes or as a URL. Both happen here — the library
/// hands over data, the catalogue hands over a link — and the difference matters
/// only at the point something draws it.
enum ResolvedArtwork: Equatable, Sendable {
    case data(Data)
    case remote(URL)
}

// MARK: - Store

/// Resolves and caches the images for one profile page.
///
/// One store per page rather than per tile: the artist lookups batch into a
/// single Spotify round trip, and a tile that owns its own request re-fires it
/// every time the grid re-lays out.
@MainActor
final class ProfileArtworkStore: ObservableObject {

    /// Artist name (exactly as the stat spells it) → photo.
    @Published private(set) var artistImages: [String: ResolvedArtwork] = [:]
    /// `shared_playlists` row id → cover.
    @Published private(set) var playlistCovers: [UUID: ResolvedArtwork] = [:]

    /// The avatar's actual bytes.
    ///
    /// `AvatarView` draws the same image straight from its URL and never needs
    /// this — the page's colour wash does, and no amount of link is a colour.
    /// It's the one image here fetched for something other than drawing.
    @Published private(set) var avatar: Data?
    private var triedAvatar = false

    /// Everything asked about, hit or miss. Without it, a name the catalogue
    /// has never heard of is looked up again on every redraw.
    private var triedArtists:   Set<String> = []
    private var triedPlaylists: Set<UUID>   = []

    /// Cover lookups are one network round trip each and the grid shows six.
    /// Someone with forty public playlists doesn't need forty requests fired the
    /// moment their profile opens.
    private static let coverLookupLimit = 12

    // MARK: Avatar

    /// Fetched once per page. A failure is silent and final: the wash has a
    /// brand-coloured fallback, and retrying a 404 avatar on every redraw would
    /// cost more than the picture is worth.
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

        // The stat records the credit — "Drake feat. 21 Savage" — and there is no
        // Spotify artist by that name. Several credits often reduce to the same
        // person, so they share one lookup and one answer.
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

        // Strict best-first. The published cover is the real one and outranks any
        // local guess, but the owner's own copy is the same image for free, so it
        // goes first and saves a download on the profile you look at most.
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

    /// Last resort before the network: anyone who happens to own some of these
    /// songs already gets the album art from their own copy. Ranked below the
    /// published cover, because a song from the playlist is not the playlist.
    private func localTrackCover(for summary: PublicPlaylistSummary,
                                 library: LibraryService) -> Data? {
        summary.tracks.lazy.compactMap { library.track(id: $0.id)?.displayArtwork }.first
    }

    /// Stands in the first song's album art for a cover nobody published. Not the
    /// playlist's real cover, but it's the playlist's actual music, which beats a
    /// grey square by more than it costs.
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

/// Draws whichever shape the artwork arrived in, falling back to `placeholder`
/// while a remote image loads or when there was never anything to draw.
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
