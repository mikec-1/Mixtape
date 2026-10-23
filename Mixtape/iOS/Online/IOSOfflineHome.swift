// Home with no connection. Everything here is made from what's on the phone:
// downloaded playlists and albums, a mix of your downloads, one per artist,
// and the songs themselves.

#if os(iOS)
import SwiftUI

struct IOSOfflineHome: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(IOSAppState.self) private var iosAppState
    var downloads: DownloadManager

    @State private var showsAllSongs = false

    /// Shown before the list expands.
    private static let collapsedSongs = 5

    var body: some View {
        let songs = deps.libraryService.tracks.filter { downloads.downloadedTrackIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 30) {
            if songs.isEmpty {
                emptyState
            } else {
                tiles
                offlineMix(songs)
                artistMixes(songs)
                songList(songs)
            }
        }
    }

    // MARK: Tiles

    private var playlists: [Playlist] {
        deps.libraryService.playlists.filter { downloads.isFullyDownloaded($0.trackIDs) }
    }
    private var albums: [Album] {
        deps.libraryService.albums.filter { SavedAlbumsService.shared.isSaved($0) && downloads.isFullyDownloaded($0.trackIDs) }
    }

    /// Spotify's two-column tiles, downloaded playlists then albums.
    @ViewBuilder
    private var tiles: some View {
        let playlists = playlists.prefix(6), albums = albums.prefix(8 - playlists.count)
        if !playlists.isEmpty || !albums.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(playlists) { p in
                    Button { iosAppState.openLibraryPlaylist(p) } label: {
                        tile(p.name) { PlaylistArtwork(playlist: p, size: 56, cornerRadius: 0) }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(albums) { a in
                    NavigationLink(value: a) {
                        tile(a.title) {
                            ArtworkThumbnail(data: a.artworkData, artworkRef: .album(a.id), size: 56,
                                             cornerRadius: 0, placeholder: MixtapeIcons.album)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tile<A: View>(_ title: String, @ViewBuilder art: () -> A) -> some View {
        HStack(spacing: 8) {
            art().frame(width: 56, height: 56).clipped()
            Text(title)
                .font(.system(size: MixFontScale.size(13), weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .background(Color.mixTextPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Mixes

    /// Up to 50 downloads in an order that changes each launch (hash seeds are per process), so it's a new mix
    /// each time without reshuffling on every redraw.
    private func offlineMix(_ songs: [Track]) -> some View {
        let mix = Array(songs.sorted { $0.id.hashValue < $1.id.hashValue }.prefix(50))
        return section("While you're offline") {
            IOSFeatureCard(
                title: "Offline Mix",
                byline: "Mixtape",
                detail: "\(mix.count) songs, all downloaded",
                tint: MixCoverStyle.color(for: "offline:Offline Mix"),
                pill: ("Shuffle", "shuffle", { play(mix.shuffled(), as: "Offline Mix") }),
                onOpen: { open(mix, as: "Offline Mix") },
                onPlay: { play(mix, as: "Offline Mix") }
            ) {
                DownloadCollage(tracks: mix)
            } actions: {
                Button { play(mix, as: "Offline Mix") } label: { Label("Play", systemImage: "play.fill") }
                Button { play(mix.shuffled(), as: "Offline Mix") } label: { Label("Shuffle", systemImage: "shuffle") }
            }
        }
    }

    /// One mix per artist with at least three downloads, most downloaded first.
    @ViewBuilder
    private func artistMixes(_ songs: [Track]) -> some View {
        let byArtist = Dictionary(grouping: songs, by: \.displayArtistName)
            .filter { $0.value.count >= 3 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(10)
        if !byArtist.isEmpty {
            section("Your downloaded artists") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(byArtist, id: \.key) { artist, tracks in
                            Button { open(tracks.shuffled(), as: "\(artist) Mix") } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    DownloadCollage(tracks: tracks)
                                        .frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Text("\(artist) Mix")
                                        .font(.system(size: MixFontScale.size(13), weight: .semibold))
                                        .foregroundStyle(Color.mixTextPrimary)
                                        .lineLimit(1)
                                    Text("\(tracks.count) songs")
                                        .font(.system(size: MixFontScale.size(12)))
                                        .foregroundStyle(Color.mixTextSecondary)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(artist) Mix, \(tracks.count) songs")
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Songs

    private func songList(_ songs: [Track]) -> some View {
        let shown = showsAllSongs ? songs : Array(songs.prefix(Self.collapsedSongs))
        return section("Downloaded songs") {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { track in
                    TrackRowView(track: track,
                                 isCurrent: engine.queue.currentTrack?.id == track.id,
                                 isPlaying: engine.state.isPlaying && engine.queue.currentTrack?.id == track.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await engine.play(track: track, in: songs, source: .named("Downloaded")) }
                        }
                }
            }
            if songs.count > Self.collapsedSongs {
                Button {
                    Haptics.play(.light)
                    withMixAnimation(.easeInOut(duration: 0.2)) { showsAllSongs.toggle() }
                } label: {
                    Text(showsAllSongs ? "Show less" : "Show all \(songs.count)")
                        .font(.mixButtonSmall)
                        .foregroundStyle(Color.mixTextPrimary)
                        .padding(.horizontal, 20)
                        .frame(height: 34)
                        .overlay(Capsule().stroke(Color.mixTextTertiary, lineWidth: 1))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
            Text("Nothing downloaded yet")
                .font(.mixTitle2.bold())
                .foregroundStyle(Color.mixTextPrimary)
            Text("Songs, playlists and albums you download play here with no connection.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.mixTitle.bold())
                .foregroundStyle(Color.mixTextPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func play(_ tracks: [Track], as name: String) {
        guard let first = tracks.first else { return }
        Task { await engine.play(track: first, in: tracks, source: .named(name)) }
    }

    private func open(_ tracks: [Track], as name: String) {
        DiscoverSessionStore.shared.path.append(.downloads(title: name, ids: tracks.map(\.id)))
    }
}

/// Four different covers in a square, or the one there is.
private struct DownloadCollage: View {
    let tracks: [Track]

    var body: some View {
        var seen = Set<String>()
        let covers = Array(tracks.filter { seen.insert($0.albumTitle).inserted }.prefix(4))
        if covers.count == 4 {
            VStack(spacing: 1) {
                HStack(spacing: 1) { cover(covers[0]); cover(covers[1]) }
                HStack(spacing: 1) { cover(covers[2]); cover(covers[3]) }
            }
        } else {
            cover(covers.first)
        }
    }

    private func cover(_ track: Track?) -> some View {
        Color.mixSurface2
            .overlay {
                ArtworkThumbnail(data: track?.artworkData, artworkRef: track.map { .track($0.id) },
                                 size: nil, cornerRadius: 0, placeholder: MixtapeIcons.track)
            }
            .clipped()
    }
}

/// A mix of downloads opened from Home. The same page as every other mix, playing the library's own files
/// so it works with no connection.
struct OfflineMixPage: View {
    let title: String
    let ids: [UUID]

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        // Looked up live, so a removed download drops out.
        let byID = Dictionary(deps.libraryService.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = ids.compactMap { byID[$0] }
        let online = tracks.map(OnlinePlaybackCoordinator.onlineForm)
        let local = Dictionary(zip(online.map(\.id), tracks), uniquingKeysWith: { a, _ in a })
        let artists = Set(tracks.map(\.displayArtistName))
        let artist = artists.count == 1 ? (artists.first ?? "") : ""
        MixDetailPage(
            mix: PersonalMix(id: "offline:\(title)", seedArtist: artist, title: title,
                             subtitle: artist.isEmpty ? "Made from your downloads" : "Your \(artist) downloads",
                             tracks: online, covers: []),
            onPlay: { picked, shown in play(local[picked.id], in: shown.compactMap { local[$0.id] }) },
            onShuffle: {
                let shuffled = tracks.shuffled()
                play(shuffled.first, in: shuffled)
            }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func play(_ track: Track?, in tracks: [Track]) {
        guard let track else { return }
        Task { await engine.play(track: track, in: tracks, source: .named(title)) }
    }
}
#endif
