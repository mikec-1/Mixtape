// DiscoverArtistCounts.swift
// Mixtape — Features/Online
//
// The metadata block under an artist's name on a Discover artist page: what
// the catalogue holds, and — the part that is actually about you — how much of
// this artist you have already liked.
//
// Shared by the macOS (OnlineDiscoverView) and iOS (IOSDiscoverComponents)
// artist pages so the two can't drift apart.

import SwiftUI

struct DiscoverArtistCounts: View {

    /// The Deezer artist's display name — the only thing we can match local
    /// favourites against, see `likedSummary`.
    let artistName: String
    /// The artist's releases, and the songs on them.
    ///
    /// `songCount` used to be `topTracks.count`, which was never a fact about
    /// the artist — it was the limit on the "most played" request, so every
    /// artist alive had exactly "10 songs". It's now totalled from the track
    /// counts of the releases listed beside it, so the two numbers describe the
    /// same set of records and neither claims more than it knows.
    let songCount: Int
    let releaseCount: Int
    /// Opens the liked-songs page. Nil leaves the line as plain text, for any
    /// caller with nowhere to push a page to.
    var onOpenLiked: (() -> Void)? = nil

    @EnvironmentObject private var deps: AppDependencies

    /// Cached, not computed in `body`.
    ///
    /// The summary walks Favourites and builds a map of the whole library —
    /// O(library) — and `body` runs on every publish from anything this page
    /// observes, which on a 2000-song library is a visible stall while
    /// browsing. It only changes when the favourites do, so it's recomputed on
    /// that and nothing else.
    @State private var liked: String?

    private var favouritesFingerprint: String {
        let count = deps.libraryService.playlists.first(where: \.isFavourites)?.trackIDs.count ?? 0
        return "\(artistName)#\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(catalogueLine)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextSecondary)

            // Absent entirely when nothing is liked: "0 liked songs" is noise on
            // the artist pages you have never touched, which is most of them.
            if let liked {
                if let onOpenLiked {
                    Button(action: onOpenLiked) { likedLine(liked, isLink: true) }
                        .buttonStyle(.plain).mixHandCursor()
                        .help("Show these songs")
                } else {
                    likedLine(liked, isLink: false)
                }
            }
        }
        .task(id: favouritesFingerprint) { liked = likedSummary }
    }

    /// "412 songs · 40 releases". The song half is dropped when it's zero —
    /// which means the listing carried no per-release track counts, not that the
    /// artist has no songs, and "0 songs" over a page full of them is worse than
    /// saying nothing.
    private var catalogueLine: String {
        let releases = "\(releaseCount) release\(releaseCount == 1 ? "" : "s")"
        guard songCount > 0 else { return releases }
        return "\(songCount) song\(songCount == 1 ? "" : "s") \u{00B7} " + releases
    }

    /// Accent, because a like is a state the user has set — the same reason the
    /// filled heart is accent everywhere else. The chevron is the only thing
    /// that changes when the line is tappable: the colour already reads as
    /// interactive, so without it a plain summary and a link look identical.
    private func likedLine(_ text: String, isLink: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
            Text(text)
            if isLink {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.mixPrimary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Local favourites for an online artist

    /// "7 liked songs across 3 albums", or nil when nothing by this artist is
    /// favourited.
    ///
    /// The album half is dropped when everything liked sits on one release —
    /// "across 1 album" costs a line and says nothing. There is no such thing
    /// as liking an *album* in Mixtape (favourites are per track), so the
    /// releases figure is how many distinct albums the liked songs come from.
    private var likedSummary: String? {
        let liked = Self.likedTracks(by: artistName, in: deps.libraryService)
        guard !liked.isEmpty else { return nil }

        let songs = "\(liked.count) liked song\(liked.count == 1 ? "" : "s")"
        let albums = Set(
            liked.map { $0.albumTitle.trimmingCharacters(in: .whitespaces).lowercased() }
                 .filter { !$0.isEmpty }
        )
        guard albums.count > 1 else { return songs }
        return "\(songs) across \(albums.count) albums"
    }

    /// Every library track credited to `artistName` that you have favourited,
    /// most recently liked first.
    ///
    /// Shared with `DiscoverLikedSongsPage`, which is the whole point of it
    /// being here: two copies of this filter is how "24 liked songs" ends up
    /// opening a list of 23.
    static func likedTracks(by artistName: String, in library: LibraryService) -> [Track] {
        // One lookup off the Favourites system playlist rather than a repo hit
        // per track, and it's @Published, so liking a song from the artist page
        // updates the line immediately.
        guard let favourites = library.playlists.first(where: \.isFavourites),
              !favourites.trackIDs.isEmpty else { return [] }
        // Every spelling this library uses for this artist, resolved once for
        // the whole walk rather than per track.
        let wanted = ArtistAliases.spellings(of: artistName)
        guard !wanted.isEmpty else { return [] }

        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Walked in playlist order rather than filtering `library.tracks`,
        // because Favourites is append-ordered — so reversed, this is
        // most-recently-liked first. That ordering is the only thing this list
        // can tell you that the artist page doesn't already.
        return favourites.trackIDs.reversed().compactMap { id in
            guard let track = byID[id],
                  isCredited(on: track.artistName, matching: wanted) else { return nil }
            return track
        }
    }

    /// Whether `credit` (a library track's artist string) names this artist,
    /// `wanted` being every folded spelling of them (`ArtistAliases.spellings`).
    ///
    /// Discover artists come from Deezer and carry no local id, so a name is
    /// the only bridge to the library. The credit string is split with the same
    /// rule the library itself uses to file tracks under artists
    /// (`ImportService.creditedArtists`) so these counts agree with the local
    /// artist page, and each part is compared whole. Substring matching was the
    /// obvious shortcut and is wrong: it counts every Kanye West track for an
    /// artist called "Ye". The alias table is the narrow, learned version of
    /// what substring matching was reaching for — it only ever equates two
    /// names Deezer itself has already equated.
    private static func isCredited(on credit: String, matching wanted: Set<String>) -> Bool {
        ImportService.creditedArtists(from: credit).contains {
            wanted.contains(ArtistAliases.fold($0))
        }
    }
}
