// IOSDiscoverComponents.swift
// Mixtape — iOS/Online
//
// Rows, cards, song hero, and drill-down pages for iOS Discover. Touch versions
// of the macOS OnlineDiscoverView components — play is a tap, secondary actions
// live in a long-press menu instead of on hover.

#if os(iOS)
import SwiftUI

// MARK: - Navigation destinations (shared by view + pages)

/// A pushed Discover page. Hashable so it can drive a NavigationStack path.
enum DiscoverDestination: Hashable {
    case artist(OnlineArtist)
    case album(OnlineAlbum)
    case genre(BrowseGenre)
}

/// The promoted "Top result" — an artist or a song.
enum IOSTopResult {
    case artist(OnlineArtist)
    case song(OnlineTrack)
}

// MARK: - Explicit badge

/// The small "E" label shown next to tracks with explicit lyrics.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.mixTextSecondary)
            .frame(width: 14, height: 14)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Explicit")
    }
}

// MARK: - Shared artwork view

/// Square or circular remote artwork with a placeholder.
func discoverArtwork(url: URL?, circle: Bool, size: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : 6, style: .continuous)
    return AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
    } placeholder: {
        ZStack {
            Color.mixSurface2
            Image(systemName: circle ? "person.fill" : "music.note")
                .font(.system(size: size * 0.3))
                .foregroundStyle(Color.mixTextTertiary)
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}

// MARK: - Song row

struct IOSSongRow: View {
    let song: OnlineTrack
    let isResolving: Bool
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAdd: () -> Void
    /// Opens the song's album / artist. Nil hides the menu item.
    var onOpenAlbum: (() -> Void)? = nil
    var onOpenArtist: (() -> Void)? = nil
    /// Leading track number (album page). Nil hides it.
    var index: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            ZStack {
                discoverArtwork(url: song.artworkURL, circle: false, size: 44)
                if isResolving {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        .frame(width: 44, height: 44)
                    ProgressView().controlSize(.small).tint(.white)
                } else if isCurrent {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.4))
                        .frame(width: 44, height: 44)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.mixPrimary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }
                Text(song.artistName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            } else if song.duration > 0 {
                Text(Self.formatTime(song.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
            Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
            Divider()
            Button("Add to Library", systemImage: "plus", action: onAdd)
            if onOpenAlbum != nil || onOpenArtist != nil { Divider() }
            if let onOpenArtist {
                Button("Go to Artist", systemImage: "music.mic", action: onOpenArtist)
            }
            if let onOpenAlbum {
                Button("Go to Album", systemImage: "square.stack", action: onOpenAlbum)
            }
        }
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Wide song hero (song-centric top result)

struct IOSWideSongHero: View {
    let song: OnlineTrack
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var isResolving: Bool = false
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onOpenAlbum: (() -> Void)? = nil
    var onOpenArtist: (() -> Void)? = nil

    private var isThisPlaying: Bool { isCurrent && isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                discoverArtwork(url: song.artworkURL, circle: false, size: 110)
                    .overlay {
                        if isResolving {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Song")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                        if song.isExplicit { ExplicitBadge() }
                    }
                    Text(song.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(2)
                    Text(song.artistName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Button(action: onPlay) {
                Label(isThisPlaying ? "Pause" : "Play",
                      systemImage: isThisPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 28).padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(Color.mixPrimary, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(isThisPlaying ? "Pause" : "Play",
                   systemImage: isThisPlaying ? "pause.fill" : "play.fill", action: onPlay)
            if let onPlayNext {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
            }
            if let onAddToQueue {
                Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
            }
            if let onAdd {
                Divider()
                Button("Add to Library", systemImage: "plus", action: onAdd)
            }
            if onOpenArtist != nil || onOpenAlbum != nil { Divider() }
            if let onOpenArtist {
                Button("Go to Artist", systemImage: "music.mic", action: onOpenArtist)
            }
            if let onOpenAlbum {
                Button("Go to Album", systemImage: "square.stack", action: onOpenAlbum)
            }
        }
    }
}

// MARK: - Top result card

struct IOSTopResultCard: View {
    let top: IOSTopResult
    let onOpenArtist: (OnlineArtist) -> Void
    let onPlay: (OnlineTrack) -> Void

    var body: some View {
        switch top {
        case .artist(let artist):
            card(imageURL: artist.imageURL, circle: true,
                 title: artist.name, subtitle: "Artist") { onOpenArtist(artist) }
        case .song(let song):
            card(imageURL: song.artworkURL, circle: false,
                 title: song.title, subtitle: "Song · \(song.artistName)") { onPlay(song) }
        }
    }

    private func card(imageURL: URL?, circle: Bool, title: String, subtitle: String,
                      action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            discoverArtwork(url: imageURL, circle: circle, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Artist circle

struct IOSArtistCircle: View {
    let artist: OnlineArtist
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            discoverArtwork(url: artist.imageURL, circle: true, size: 104)
            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text("Artist")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Album card

struct IOSAlbumCard: View {
    let album: OnlineAlbum
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            discoverArtwork(url: album.coverURL, circle: false, size: 140)
            Text(album.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text(album.artistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Section header

func discoverSectionHeader(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(Color.mixTextPrimary)
}

// MARK: - Artist detail page

struct IOSDiscoverArtistPage: View {
    let artist: OnlineArtist
    /// Push another page (album / artist) and play a track in context.
    let onOpenAlbum: (OnlineAlbum) -> Void
    let onOpenArtist: (OnlineArtist) -> Void
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @State private var topTracks: [OnlineTrack]  = []
    @State private var albums:    [OnlineAlbum]  = []
    @State private var related:   [OnlineArtist] = []
    @State private var loading = true
    @State private var tracksExpanded = false
    @State private var albumsExpanded = false

    private let albumColumns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    private let collapsedTrackCount = 5
    private let collapsedAlbumCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroHeader
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if !topTracks.isEmpty { popularSection }
                    if !albums.isEmpty { albumsGrid }
                    if !related.isEmpty { similarArtistsSection }
                }
            }
            .padding(20)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id) { await load() }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            discoverArtwork(url: artist.imageURL, circle: true, size: 140)
            Text("Artist").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
            Text(artist.name).font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(2)
            if let first = topTracks.first {
                Button {
                    onPlay(first, topTracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Color.mixPrimary, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var popularSection: some View {
        let shown = tracksExpanded ? topTracks : Array(topTracks.prefix(collapsedTrackCount))
        return VStack(alignment: .leading, spacing: 6) {
            discoverSectionHeader("Popular")
            ForEach(shown) { song in row(song) }
            if topTracks.count > collapsedTrackCount {
                expandButton(expanded: $tracksExpanded)
            }
        }
    }

    private func row(_ song: OnlineTrack) -> some View {
        IOSSongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: { onPlay(song, topTracks) },
            onPlayNext: { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd: { Task { await coordinator.addToLibrary(song) } },
            onOpenAlbum: {
                Task {
                    if let al = await deps.itunesClient.resolveAlbum(for: song) {
                        await MainActor.run { onOpenAlbum(al) }
                    }
                }
            },
            onOpenArtist: {
                Task {
                    if let a = await deps.itunesClient.resolveArtist(name: song.artistName, trackID: song.sourceID) {
                        await MainActor.run { onOpenArtist(a) }
                    }
                }
            }
        )
    }

    private var albumsGrid: some View {
        let shown = albumsExpanded ? albums : Array(albums.prefix(collapsedAlbumCount))
        return VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Albums")
            LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 18) {
                ForEach(shown) { album in
                    IOSAlbumCard(album: album) { onOpenAlbum(album) }
                }
            }
            if albums.count > collapsedAlbumCount {
                expandButton(expanded: $albumsExpanded)
            }
        }
    }

    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Fans also like")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(related) { artist in
                        IOSArtistCircle(artist: artist) { onOpenArtist(artist) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func expandButton(expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
        } label: {
            Label(expanded.wrappedValue ? "Show less" : "Show more",
                  systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func load() async {
        loading = true
        async let top = deps.itunesClient.artistTopTracks(artistId: artist.id)
        async let alb = deps.itunesClient.artistAlbums(artistId: artist.id)
        async let rel = deps.itunesClient.relatedArtists(artistId: artist.id)
        topTracks = await top
        albums = await alb
        related = await rel
        loading = false
    }
}

// MARK: - Album detail page

struct IOSDiscoverAlbumPage: View {
    let album: OnlineAlbum
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @State private var tracks: [OnlineTrack] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    discoverArtwork(url: album.coverURL, circle: false, size: 130)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Album").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                        Text(album.title).font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.mixTextPrimary).lineLimit(3)
                        Text(album.artistName).font(.system(size: 14))
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                    Spacer(minLength: 0)
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, song in
                        IOSSongRow(
                            song: song,
                            isResolving: coordinator.resolvingID == song.id,
                            isCurrent: coordinator.nowPlayingID == song.id,
                            isPlaying: engine.state.isPlaying,
                            onPlay: { onPlay(song, tracks) },
                            onPlayNext: { Task { await coordinator.playNext(song) } },
                            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
                            onAdd: { Task { await coordinator.addToLibrary(song) } },
                            onOpenArtist: {
                                Task {
                                    if let a = await deps.itunesClient.resolveArtist(name: song.artistName, trackID: song.sourceID) {
                                        await MainActor.run { onOpenArtist(a) }
                                    }
                                }
                            },
                            index: idx + 1
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) {
            loading = true
            tracks = await deps.itunesClient.albumTracks(album: album)
            loading = false
        }
    }
}

// MARK: - Browse landing: trending song card

/// Tap-to-play "Trending now" card. Spinner overlays the art while audio resolves.
struct IOSBrowseSongCard: View {
    let song: OnlineTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let isResolving: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            discoverArtwork(url: song.artworkURL, circle: false, size: 150)
                .overlay {
                    if isResolving {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    } else if isCurrent && isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.mixPrimary)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            HStack(spacing: 5) {
                Text(song.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                if song.isExplicit { ExplicitBadge() }
            }
            Text(song.artistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Browse landing: genre tile

/// Colourful "Browse all" tile — hue picked by position, artwork tucked into the
/// corner at an angle. Touch version of the macOS `GenreTile`.
struct IOSGenreTile: View {
    let genre: BrowseGenre
    let index: Int
    let onTap: () -> Void

    /// Cycled by position so a tile's colour stays stable across launches.
    private static let palette: [Color] = [
        Color(red: 0.83, green: 0.20, blue: 0.45), Color(red: 0.10, green: 0.45, blue: 0.42),
        Color(red: 0.18, green: 0.22, blue: 0.55), Color(red: 0.55, green: 0.20, blue: 0.80),
        Color(red: 0.90, green: 0.40, blue: 0.15), Color(red: 0.15, green: 0.50, blue: 0.70),
        Color(red: 0.60, green: 0.45, blue: 0.10), Color(red: 0.70, green: 0.15, blue: 0.25),
        Color(red: 0.20, green: 0.55, blue: 0.30), Color(red: 0.40, green: 0.25, blue: 0.60),
    ]

    private var color: Color { Self.palette[index % Self.palette.count] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            color
            Text(genre.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(14)
            AsyncImage(url: genre.pictureURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.clear }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .rotationEffect(.degrees(25))
                .offset(x: 18, y: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .clipped()
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Genre detail page (a Browse all tile opened)

/// Popular artists within a genre; tap one to open their page.
struct IOSDiscoverGenrePage: View {
    let genre: BrowseGenre
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps: AppDependencies

    @State private var artists: [OnlineArtist] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if artists.isEmpty {
                    Text("Nothing to show for this genre right now.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mixTextSecondary)
                } else {
                    discoverSectionHeader("Popular artists")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(artists) { artist in
                            IOSArtistCircle(artist: artist) { onOpenArtist(artist) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: genre.id) {
            loading = true
            artists = await deps.itunesClient.genreArtists(genreId: genre.id)
            loading = false
        }
    }
}
#endif
