// The metadata under a Discover artist's name: catalogue counts and how much
// you've liked. Shared by macOS and iOS artist pages.

import SwiftUI

struct DiscoverArtistCounts: View {

    /// The Deezer name, matched against local favourites. See `likedSummary`.
    let artistName: String
    /// Totalled from the listed releases' track counts, so both numbers describe the same records.
    let songCount: Int
    let releaseCount: Int
    /// Opens the liked-songs page. Nil leaves the line as plain text.
    var onOpenLiked: (() -> Void)? = nil

    @EnvironmentObject private var deps: AppDependencies

    /// Cached since the summary is O(library). Recomputed only when favourites change.
    @State private var liked: String?
    /// How much *you* played this artist. Loaded once per artist: it reads play history.
    @State private var standing: ArtistStanding?

    private var favouritesFingerprint: String {
        let count = deps.libraryService.playlists.first(where: \.isFavourites)?.trackIDs.count ?? 0
        return "\(artistName)#\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(catalogueLine)
                .font(.system(size: MixFontScale.size(12)))
                .foregroundStyle(Color.mixTextSecondary)

            // Hidden until you've played them.
            if let standing {
                Text(standing.summary)
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextSecondary)
            }

            // Hidden when nothing is liked.
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
        .task(id: artistName) { standing = deps.statsService.artistStanding(for: artistName) }
    }

    /// "412 songs · 40 releases". Songs are dropped when zero, which means no per-release counts.
    private var catalogueLine: String {
        let releases = "\(releaseCount) release\(releaseCount == 1 ? "" : "s")"
        guard songCount > 0 else { return releases }
        return "\(songCount) song\(songCount == 1 ? "" : "s") \u{00B7} " + releases
    }

    /// Accent like the filled heart. The chevron marks it as a link.
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
        .font(.system(size: MixFontScale.size(12), weight: .semibold))
        .foregroundStyle(Color.mixPrimary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Local favourites for an online artist

    /// "7 liked songs across 3 albums", or nil. The album half is dropped when it's one album.
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

    /// Favourited library tracks by `artistName`, most recently liked first.
    /// Shared with `DiscoverLikedSongsPage` so the count and the list agree.
    static func likedTracks(by artistName: String, in library: LibraryService) -> [Track] {
        // One lookup off Favourites, which is `@Published`, so likes update the line immediately.
        guard let favourites = library.playlists.first(where: \.isFavourites),
              !favourites.trackIDs.isEmpty else { return [] }
        // Every spelling of this artist, resolved once.
        let wanted = ArtistAliases.spellings(of: artistName)
        guard !wanted.isEmpty else { return [] }

        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Favourites is append-ordered, so reversed is most recently liked first.
        return favourites.trackIDs.reversed().compactMap { id in
            guard let track = byID[id],
                  isCredited(on: track.artistName, matching: wanted) else { return nil }
            return track
        }
    }

    /// Whether `credit` names this artist, `wanted` being its folded spellings.
    /// Split with `ImportService.creditedArtists` and compared whole. Substring
    /// matching would count every Kanye West track for "Ye".
    private static func isCredited(on credit: String, matching wanted: Set<String>) -> Bool {
        ImportService.creditedArtists(from: credit).contains {
            wanted.contains(ArtistAliases.fold($0))
        }
    }
}
