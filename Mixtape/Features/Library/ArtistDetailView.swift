import SwiftUI
import Combine

public struct ArtistDetailView: View {

    let artist: Artist

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @Environment(QueueService.self) private var queueService
    /// The header shuffle is this list's setting. See `ShufflePreferences`.
    private var shufflePrefs: ShufflePreferences { .shared }

    private var tracks: [Track] {
        deps.libraryService.tracks(by: artist)
    }

    private var albums: [Album] {
        let ids = Set(artist.albumIDs)
        return deps.libraryService.albums.filter { ids.contains($0.id) }
    }

    /// Bumped when the download manager publishes, since `body` reads its state
    /// without observing it.
    @State private var downloadTick = 0
    /// How much *you* played this artist. Loaded in `.task`: it reads play history.
    @State private var standing: ArtistStanding?

    public var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity)
                if !albums.isEmpty  { albumsSection }
                if !tracks.isEmpty  { tracksSection }
                if albums.isEmpty && tracks.isEmpty { emptyState }
            }
            .padding(.bottom, 24)
        }
        // On the container so it stays put while scrolling, and tints the titlebar.
        .artworkWash(source: artist.displayArtwork)
        .background(MixPageBackground())
        .miniPlayerSafeArea()
        // The top tracks lead the list, so warm those.
        .task(id: artist.id) {
            deps.onlineCoordinator.prefetchResolvable(tracks)
            standing = deps.statsService.artistStanding(for: artist.name)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: "Artist",
            title: artist.name,
            subtitle: artist.bio,
            metadata: metadataLine,
            coverIsCircular: true
        ) { size in
            // No manual photo refresh: LibraryService's backfill replaces stand-ins itself.
            ArtworkThumbnail(
                data: artist.artworkData, artworkRef: .artist(artist.id),
                size: size,
                cornerRadius: size / 2,
                placeholder: MixtapeIcons.artist
            )
        } actions: {
            HeroActionBar(
                isPlaying: isPlayingThisArtist,
                isShuffling: shufflePrefs.shuffles(shuffleKey),
                isEmpty: tracks.isEmpty,
                onPlay: {
                    if isPlayingThisArtist {
                        engine.pause()
                    } else if isPausedInThisArtist {
                        engine.resume()
                    } else {
                        let shuffles = shufflePrefs.shuffles(shuffleKey)
                        engine.queue.setShuffle(shuffles)
                        guard let first = shuffles
                                ? tracks.randomElement() : tracks.first else { return }
                        Task { await engine.play(track: first, in: tracks, source: .named(artist.name)) }
                    }
                },
                onShuffle: { shufflePrefs.toggle(shuffleKey) }
            ) {
                ShareHeroButton(.artist(artist))

                // Same overflow menu as the album and playlist pages.
                Menu { ArtistActionsMenu(name: artist.name, showsShare: false) } label: {
                    HeroCircleLabel(systemImage: "ellipsis")
                }
                #if os(macOS)
                // Otherwise a Menu draws as a bordered pop-up with a chevron.
                .menuStyle(.button)
                .buttonStyle(.plain).mixHandCursor()
                .menuIndicator(.hidden)
                #endif
                .frame(width: 40, height: 40)
            }
        }
    }

    /// Playing one of this artist's songs, asked of the queue's source. See
    /// `PlaylistDetailView.isPlayingThisPlaylist`.
    private var isPlayingThisArtist: Bool {
        engine.state.isPlaying && queueService.source == .named(artist.name)
    }

    private var isPausedInThisArtist: Bool {
        engine.state == .paused && queueService.source == .named(artist.name)
    }

    private var shuffleKey: ShufflePreferences.Key { .artist(artist.name) }

    private var metadataLine: String {
        var parts: [String] = []
        if !albums.isEmpty { parts.append("\(albums.count) album\(albums.count == 1 ? "" : "s")") }
        if !tracks.isEmpty { parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")") }
        // Lowercased: it joins a counts line, not a sentence of its own.
        if let standing { parts.append(standing.summary.lowercased()) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Albums")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnail(
                                    data: album.artworkData, artworkRef: .album(album.id),
                                    size: 130,
                                    cornerRadius: 10,
                                    placeholder: MixtapeIcons.album
                                )
                                Text(album.title)
                                    .font(.mixLabel)
                                    .foregroundStyle(Color.mixTextPrimary)
                                    .lineLimit(1)
                                    .frame(width: 130, alignment: .leading)
                                if let year = album.year {
                                    Text(String(year))
                                        .font(.mixCaption)
                                        .foregroundStyle(Color.mixTextTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Songs Section

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Songs")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.mixSeparator)

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRowView(
                    track:          track,
                    isCurrent:      engine.queue.currentTrack?.id == track.id,
                    isPlaying:      engine.state.isPlaying,
                    availability:   deps.downloadManager.status(for: track.id),
                    isResolving:    engine.routingTrackIDs.contains(track.id)
                )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await engine.play(track: track, in: tracks, source: .named(artist.name)) }
                }
                // No "Go to Artist" on the artist's own page.
                .contextMenu {
                    LibrarySongMenu(targets: [track], onPlay: {
                        Task { await engine.play(track: track, in: tracks, source: .named(artist.name)) }
                    }, showsGoToArtist: false)
                }

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 72)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: MixtapeIcons.artist)
                .font(.system(size: 44))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No tracks found")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Import music by this artist to see it here.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mixTitle2)
            .foregroundStyle(Color.mixTextPrimary)
    }
}

// MARK: - Preview
// Guarded because `previewArtists` is DEBUG-only; Release would fail to build.

#if DEBUG
#Preview {
    NavigationStack {
        ArtistDetailView(artist: Artist.previewArtists[0])
            .environment(AppDependencies())
            .environment(PlaybackEngine(
                queue: QueueService(),
                fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
                equalizer: AudioEqualizer()
            ))
    }
}
#endif
