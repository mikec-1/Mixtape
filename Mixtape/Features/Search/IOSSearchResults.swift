// The catalogue half of the iOS search page, in macOS order: the answer, that
// artist's songs, albums, then similar artists.

#if os(iOS)
import SwiftUI

/// The pills over the results. All is the page; the rest are one list each.
enum IOSSearchFilter: String, CaseIterable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums"
}

struct IOSSearchResults: View {

    let query: String
    @Binding var filter: IOSSearchFilter
    let onOpen: (DiscoverDestination) -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator

    private var store: DiscoverSessionStore { .shared }

    /// All shows this many songs; the Songs pill shows the rest.
    private static let collapsedSongs = 5

    /// The stations on the featured artist's page, shown here as "Featuring".
    @State private var stations: [PersonalMix] = []

    private var results: DiscoverResults { store.results }

    var body: some View {
        content
            .task(id: featuredArtist?.id) {
                stations = []
                guard let artist = featuredArtist else { return }
                // The store's cache, so opening the artist next costs nothing.
                let catalogue = await store.artistCatalogue(for: artist, using: deps.itunesClient)
                guard !Task.isCancelled else { return }
                stations = StationBuilder.artistStations(artist, catalogue: catalogue)
            }
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            if store.isSearching {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        } else {
            switch filter {
            case .all:
                if let hero = results.topSong {
                    songCentricResults(hero: hero)
                } else {
                    // Sections separated by space alone, the iOS idiom.
                    VStack(alignment: .leading, spacing: 26) {
                        topResultBanner
                        featuringSection
                        if !results.albums.isEmpty       { albumsSection }
                        if !results.songs.isEmpty        { songsSection }
                        if !results.lyricMatches.isEmpty { lyricMatchesSection }
                        if !results.artists.isEmpty      { artistsSection }
                    }
                }
            case .songs:
                if allSongs.isEmpty { noMatches("songs") } else { songList(allSongs) }
            case .artists:
                if allArtists.isEmpty { noMatches("artists") } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(allArtists) { artist in
                            entityRow(url: artist.imageURL, circle: true,
                                      title: artist.name, subtitle: "Artist") {
                                onOpen(.artist(artist))
                            }
                        }
                    }
                }
            case .albums:
                if results.albums.isEmpty { noMatches("albums") } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(results.albums) { album in
                            entityRow(url: album.coverURL, circle: false, title: album.title,
                                      subtitle: [album.recordTypeLabel ?? "Album", album.artistName]
                                          .filter { !$0.isEmpty }.joined(separator: " • ")) {
                                onOpen(.album(album))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filtered lists

    /// The named song first, then everything else the search found.
    private var allSongs: [OnlineTrack] {
        guard let hero = results.topSong else { return results.songs }
        return [hero] + results.songs.filter { $0.id != hero.id }
    }

    /// The song's own artists lead when a song was the answer.
    private var allArtists: [OnlineArtist] {
        let lead = Set(results.songArtists.map(\.id))
        return results.songArtists + results.artists.filter { !lead.contains($0.id) }
    }

    private func entityRow(url: URL?, circle: Bool, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                discoverArtwork(url: url, circle: circle, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func noMatches(_ noun: String) -> some View {
        Text("No \(noun) for \u{201C}\(query)\u{201D}")
            .font(.mixSubtext)
            .foregroundStyle(Color.mixTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: - Song-centric results (a specific song was searched)

    private func songCentricResults(hero: OnlineTrack) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            IOSWideSongHero(
                song: hero,
                isCurrent: coordinator.nowPlayingID == hero.id,
                isPlaying: engine.state.isPlaying,
                isResolving: coordinator.resolvingID == hero.id,
                onPlay: {
                    if coordinator.nowPlayingID == hero.id {
                        engine.togglePlayPause()
                    } else {
                        Task { await play(hero) }
                    }
                },
                onPlayNext:   { Task { await coordinator.playNext(hero) } },
                onAddToQueue: { Task { await coordinator.addToQueue(hero) } },
                onAdd:        { Task { await coordinator.addToLibrary(hero) } },
                onOpenAlbum:  { openAlbum(for: hero) },
                onOpenArtist: { openArtist(named: $0, from: hero) },
                onWrongVersion: { Task { await coordinator.reResolveAndPlay(hero, context: [hero]) } }
            )

            if !results.songArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    discoverSectionHeader(results.songArtists.count > 1 ? "Artists" : "Artist")
                    artistShelf(results.songArtists)
                }
            }

            featuringSection

            if !results.songs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        discoverSectionHeader(moreSongsTitle)
                        Spacer(minLength: 8)
                        seeAllSongs(total: results.songs.count)
                    }
                    songList(Array(results.songs.prefix(Self.collapsedSongs)))
                }
            }

            if !results.lyricMatches.isEmpty { lyricMatchesSection }
            if !results.albums.isEmpty       { albumsSection }
            if !results.artists.isEmpty      { artistsSection }
        }
    }

    private var moreSongsTitle: String {
        if let name = results.songArtists.first?.name { return "More by \(name)" }
        return "More songs"
    }

    // MARK: - Generic sections

    /// The answer as one row. Its subtitle already says Artist or Song.
    @ViewBuilder
    private var topResultBanner: some View {
        if let top = topResult {
            IOSTopResultCard(
                top: top,
                onOpenArtist: { onOpen(.artist($0)) },
                onPlay: { track in Task { await play(track) } }
            )
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // Matches, or the closest the catalogue had. See `DiscoverResults.songsMatched`.
                discoverSectionHeader(results.songsMatched ? songsTitle : "Closest matches")
                Spacer(minLength: 8)
                seeAllSongs(total: results.songs.count)
            }
            songList(resultSongs)
        }
    }

    /// "Popular songs" when an artist is the answer.
    private var songsTitle: String {
        if case .artist = topResult { return "Popular songs" }
        return "Songs"
    }

    private func songList(_ songs: [OnlineTrack]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                songRow(song)
                if index < songs.count - 1 {
                    Divider().background(Color.mixSeparator).padding(.leading, 56)
                }
            }
        }
    }

    /// Whose stations "Featuring" shows: the answering artist, or the named song's artist.
    private var featuredArtist: OnlineArtist? {
        if results.topSong != nil { return results.songArtists.first }
        if case .artist(let artist) = topResult { return artist }
        return nil
    }

    /// Spotify's "Featuring <name>": the artist page's "Playlists with" stations.
    @ViewBuilder
    private var featuringSection: some View {
        if let artist = featuredArtist, !stations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                discoverSectionHeader("Featuring \(artist.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(stations) { station in
                            MixMosaicCard(
                                mix: station,
                                isResolving: station.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
                                onOpen: { onOpen(.mix(station)) },
                                onPlay: {
                                    guard let first = station.tracks.first else { return }
                                    Task { await play(first, context: station.tracks) }
                                })
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Fans also like")
            artistShelf(results.artists)
        }
    }

    private var lyricMatchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            discoverSectionHeader("Matching that lyric")
            ForEach(results.lyricMatches) { song in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.bubble.fill").font(.system(size: MixFontScale.size(8), weight: .bold))
                        Text("Lyrics match").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.mixAccentFill, in: Capsule())

                    songRow(song)
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(results.albums) { album in
                        IOSAlbumCard(album: album) { onOpen(.album(album)) }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func artistShelf(_ artists: [OnlineArtist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(artists) { artist in
                    IOSArtistCircle(artist: artist) { onOpen(.artist(artist)) }
                }
            }
        }
        .scrollClipDisabled()
    }

    /// Jumps to the Songs pill rather than growing the page.
    @ViewBuilder
    private func seeAllSongs(total: Int) -> some View {
        if total > Self.collapsedSongs {
            MixPillButton(title: "See all") {
                Haptics.play(.selection)
                withMixAnimation(.easeInOut(duration: 0.18)) { filter = .songs }
            }
        }
    }

    private func songRow(_ song: OnlineTrack) -> some View {
        IOSSongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: { Task { await play(song) } },
            onPlayNext:   { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd:        { Task { await coordinator.addToLibrary(song) } },
            onOpenAlbum:  { openAlbum(for: song) },
            onOpenArtist: { openArtist(named: $0, from: song) },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: [song]) } }
        )
    }

    // MARK: - Result partitioning (mirrors macOS)

    /// The search layer decides artist vs song. See `DiscoverResults.anchorIsArtist`.
    private var topResult: IOSTopResult? {
        if results.anchorIsArtist, let artist = results.artists.first { return .artist(artist) }
        if let song = results.songs.first { return .song(song) }
        if let artist = results.artists.first { return .artist(artist) }
        return nil
    }

    private var resultSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return Array(pool.prefix(Self.collapsedSongs))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Play / navigate

    /// A pick plays alone, so autoplay's recommendations follow it rather than the other results.
    private func play(_ track: OnlineTrack, context: [OnlineTrack]? = nil) async {
        store.noteSearchPick()
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context ?? [track], artworkData: artworkData)
    }

    /// `trackID` only helps for the credited act; a guest resolves by name alone.
    private func openArtist(named name: String, from track: OnlineTrack) {
        let trackID = name == track.artistName ? track.sourceID : nil
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: trackID) {
                await MainActor.run { onOpen(.artist(artist)) }
            }
        }
    }

    private func openAlbum(for track: OnlineTrack) {
        Task {
            if let album = await deps.itunesClient.resolveAlbum(for: track) {
                await MainActor.run { onOpen(.album(album)) }
            }
        }
    }
}
#endif
