// iOS Discover rows, cards, song hero and drill-down pages. Touch versions of the macOS
// OnlineDiscoverView components: tap to play, long-press for the rest.

#if os(iOS)
import SwiftUI

// MARK: - Navigation destinations (shared by view + pages)

/// A pushed Discover page. Hashable so it can drive a NavigationStack path.
enum DiscoverDestination: Hashable {
    case artist(OnlineArtist)
    case album(OnlineAlbum)
    case genre(BrowseGenre)
    /// Your favourited library songs by this artist, the only local page in the stack. Carries the artist
    /// for its photo.
    case likedSongs(OnlineArtist)
    /// Every library song matching a search ("See all").
    case librarySongs(String)
    /// A personal mix, tracks included, so the page opens instantly.
    case mix(PersonalMix)
    /// Mixtape's profile. Carries nothing: the page reads the session store.
    case mixtapeProfile
    /// Someone's profile, usually whoever a mix was made for.
    case profile(UserProfile)
    /// A community post, by share code.
    case post(String)
    /// A smart playlist, e.g. the month's tape from the end of a recap.
    case smart(SmartPlaylist)
    /// A mix of downloads from the offline Home. Ids, so the page keeps the order it was opened with.
    case downloads(title: String, ids: [UUID])
}

/// The promoted "Top result": an artist or a song.
enum IOSTopResult {
    case artist(OnlineArtist)
    case song(OnlineTrack)
}

// MARK: - Explicit badge

/// The small "E" label shown next to tracks with explicit lyrics.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: MixFontScale.size(9), weight: .bold))
            .foregroundStyle(Color.mixTextSecondary)
            .frame(width: 14, height: 14)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Explicit")
    }
}

// MARK: - Shared artwork view

/// Square or circular remote artwork with a placeholder.
func discoverArtwork(url: URL?, circle: Bool, size: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : 6, style: .continuous)
    return CachedRemoteImage(url: url) { image in
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
    var onOpenArtist: ((String) -> Void)? = nil
    /// Forget the cached source and re-resolve (macOS "Wrong Version?"). Nil hides the item.
    var onWrongVersion: (() -> Void)? = nil
    /// Leading track number (album page). Nil hides it.
    var index: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.system(size: MixFontScale.size(12)).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 26, alignment: .trailing)
            }
            ZStack {
                discoverArtwork(url: song.artworkURL, circle: false, size: 44)
                if isResolving {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        .frame(width: 44, height: 44)
                    ProgressView().controlSize(.small).tint(.white)
                } else if isCurrent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 44, height: 44)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.mixPrimary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.displayTitle)
                        .font(.system(size: MixFontScale.size(15), weight: .medium))
                        .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }
                Text(song.displayArtistName)
                    .font(.system(size: MixFontScale.size(13)))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Always visible: no hover on iOS.
            SaveToLibraryButton(trackID: song.stableTrackID,
                                identity: (song.title, song.artistName, song.duration),
                                action: onAdd)
            // Fixed width so the save button doesn't shift when the duration becomes the waveform.
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                        .mixVariableColor(isActive: isPlaying)
                } else if song.duration > 0 {
                    Text(Self.formatTime(song.duration))
                        .font(.system(size: MixFontScale.size(12)).monospacedDigit())
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu {
            OnlineSongMenu(song: song,
                           onPlay: onPlay,
                           onPlayNext: onPlayNext,
                           onAddToQueue: onAddToQueue,
                           onWrongVersion: onWrongVersion,
                           onOpenAlbum: onOpenAlbum,
                           onOpenArtist: onOpenArtist)
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
    var onOpenArtist: ((String) -> Void)? = nil
    var onWrongVersion: (() -> Void)? = nil

    private var isThisPlaying: Bool { isCurrent && isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                discoverArtwork(url: song.artworkURL, circle: false, size: 110)
                    .overlay {
                        if isResolving {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Song")
                            .font(.system(size: MixFontScale.size(12), weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                        if song.isExplicit { ExplicitBadge() }
                    }
                    Text(song.displayTitle)
                        .font(.system(size: MixFontScale.size(24), weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(2)
                    Text(song.displayArtistName)
                        .font(.system(size: MixFontScale.size(14), weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    Label(isThisPlaying ? "Pause" : "Play",
                          systemImage: isThisPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: MixFontScale.size(14), weight: .bold))
                        .padding(.horizontal, 28).padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(Color.mixAccentFill, in: Capsule())
                        .foregroundStyle(Color.mixOnAccent)
                }
                .buttonStyle(.plain).mixHandCursor()

                if let onAdd {
                    SaveToLibraryButton(trackID: song.stableTrackID,
                                        identity: (song.title, song.artistName, song.duration),
                                        action: onAdd)
                        .scaleEffect(1.2)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            OnlineSongMenu(song: song,
                           onPlay: onPlay, isPlaying: isThisPlaying,
                           onPlayNext: onPlayNext,
                           onAddToQueue: onAddToQueue,
                           onWrongVersion: onWrongVersion,
                           onOpenAlbum: onOpenAlbum,
                           onOpenArtist: onOpenArtist)
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
                 title: song.displayTitle, subtitle: "Song · \(song.displayArtistName)",
                 play: { onPlay(song) }) { onPlay(song) }
        }
    }

    /// One row, no card. A `Button` for press state, VoiceOver and keyboard focus. Songs get a separate play
    /// button, since opening and playing are different intents.
    private func card(imageURL: URL?, circle: Bool, title: String, subtitle: String,
                      play: (() -> Void)? = nil,
                      action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Button(action: action) {
                HStack(spacing: 16) {
                    discoverArtwork(url: imageURL, circle: circle, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: MixFontScale.size(20), weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: MixFontScale.size(12), weight: .medium))
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()

            if let play {
                Button {
                    Haptics.play(.light)
                    play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixOnAccent)
                        // 44pt: minimum comfortable target, same as the system's circular buttons.
                        .frame(width: 44, height: 44)
                        .background(Color.mixAccentFill, in: Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Play \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top result: \(title), \(subtitle)")
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
                .font(.mixLabel.weight(.semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { OnlineCollectionMenu(.artist(artist)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
                .font(.mixLabel.weight(.semibold))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text(album.artistName)
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Section header

func discoverSectionHeader(_ text: String) -> some View {
    Text(text)
        .font(.mixTitle.bold())
        .foregroundStyle(Color.mixTextPrimary)
}

// MARK: - Feature card

/// Spotify-style "More like X" card: cover, bold title and a play button on a dark accent-washed ground.
/// Dark in both appearances because the text is always white.
struct IOSFeatureCard<Cover: View, Actions: View>: View {
    let title: String
    let byline: String
    var detail: String? = nil
    let tint: Color
    var isResolving: Bool = false
    /// The dark capsule bottom-left ("Shuffle", "Preview"...). Nil hides it.
    var pill: (title: String, systemImage: String, action: () -> Void)? = nil
    let onOpen: () -> Void
    let onPlay: () -> Void
    @ViewBuilder let cover: () -> Cover
    /// Shared by the ... menu and the long-press menu.
    @ViewBuilder let actions: () -> Actions

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                cover()
                    .frame(width: 124, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .mixShadow(color: .black.opacity(0.35), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 0) {
                        Text(title)
                            .font(.mixTitle2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2, reservesSpace: true)
                        Spacer(minLength: 4)
                        Menu { actions() } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .padding(.top, -12)
                        .padding(.trailing, -12)
                        .accessibilityLabel("More options")
                    }
                    Text(byline)
                        .font(.mixLabel)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.mixSubtext)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2, reservesSpace: true)
                    }
                }
            }

            HStack(spacing: 12) {
                if let pill {
                    Button {
                        Haptics.play(.light)
                        pill.action()
                    } label: {
                        Label(pill.title, systemImage: pill.systemImage)
                            .font(.mixButtonSmall)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(.black.opacity(0.35), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.play(.light)
                    onPlay()
                } label: {
                    ZStack {
                        Circle().fill(.white)
                        if isResolving {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: 1)
                        }
                    }
                    .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(title)")
            }
        }
        .padding(14)
        .background {
            ZStack {
                Color(white: 0.11)
                LinearGradient(colors: [tint.opacity(0.8), tint.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .contextMenu { actions() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(byline)")
        .accessibilityAction(named: "Open", onOpen)
    }
}

// MARK: - Filter pills

/// Spotify-style filter capsules. Selection is a tinted fill plus the `isSelected` trait, not colour alone.
struct IOSFilterPills<Filter: Hashable & RawRepresentable>: View where Filter.RawValue == String {
    let filters: [Filter]
    @Binding var selection: Filter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    let isOn = filter == selection
                    Button {
                        Haptics.play(.selection)
                        withMixAnimation(.easeInOut(duration: 0.18)) { selection = filter }
                    } label: {
                        Text(filter.rawValue)
                            .font(.mixButtonSmall)
                            .foregroundStyle(isOn ? Color.mixOnAccent : Color.mixTextPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(isOn ? Color.mixAccentFill : Color.mixSurface2, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        // Fades out where the row runs out of room, instead of a hard cut. The margin lets the last pill scroll clear of it.
        .contentMargins(.trailing, 14, for: .scrollContent)
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            }
        }
    }
}

// MARK: - Artist detail page

struct IOSDiscoverArtistPage: View {
    let artist: OnlineArtist
    /// Push another page (album / artist) and play a track in context.
    let onOpenAlbum: (OnlineAlbum) -> Void
    let onOpenArtist: (OnlineArtist) -> Void
    let onOpenLiked: () -> Void
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    /// Nil pushes onto Home's stack, which is where this page used to live.
    var onOpenMix: ((PersonalMix) -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @State private var topTracks: [OnlineTrack]  = []
    @State private var albums:    [OnlineAlbum]  = []
    @State private var related:   [OnlineArtist] = []
    @State private var stations:  [PersonalMix]  = []
    @State private var fanCount:  Int?
    @State private var loading = true
    @State private var albumsExpanded = false

    private let albumColumns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    private let expandedTrackCount = 10
    private let collapsedAlbumCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                DiscoverArtistBanner(artist: artist, fanCount: fanCount, height: 220,
                                     onOpenLiked: onOpenLiked)
                VStack(alignment: .leading, spacing: 28) {
                    // Below the banner: beside the portrait a phone has no room for it.
                    playButton
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        // Same two halves as the Mac, stacked on a phone.
                        if !topTracks.isEmpty { popularSection }
                        if !albums.isEmpty { albumsGrid }
                        if !stations.isEmpty { featuringSection }
                        if !related.isEmpty { similarArtistsSection }
                        DiscoverArtistAbout(artist: artist,
                                            songCount: albums.compactMap(\.trackCount).reduce(0, +),
                                            releaseCount: albums.count,
                                            fanCount: fanCount,
                                            onOpenLiked: onOpenLiked)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(DiscoverArtistWash(artist: artist))
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id) { await load() }
    }

    /// Just the play control; the identity is in the shared banner.
    @ViewBuilder
    private var playButton: some View {
        HStack(spacing: 12) {
            if let first = topTracks.first {
                Button {
                    onPlay(first, topTracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: MixFontScale.size(14), weight: .bold))
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Color.mixAccentFill, in: Capsule())
                        .foregroundStyle(Color.mixOnAccent)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
            ShareHeroButton(.artist(artist))
            // The card's long-press menu, for anyone who's already on the page.
            Menu { OnlineCollectionMenu(.artist(artist), showsShare: false) } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
        }
    }

    private var popularSection: some View {
        let shown = Array(topTracks.prefix(expandedTrackCount))
        return VStack(alignment: .leading, spacing: 6) {
            discoverSectionHeader("Popular")
            // Numbered: the ranking is the point.
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, song in
                row(song, context: topTracks, index: index + 1)
            }
        }
    }

    /// `context` is the list the row came from, so playing from "Appears on" doesn't queue Popular.
    private func row(_ song: OnlineTrack, context: [OnlineTrack], index: Int? = nil) -> some View {
        IOSSongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: { onPlay(song, context) },
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
            onOpenArtist: { name in
                Task {
                    if let a = await deps.itunesClient.resolveArtist(
                        name: name,
                        trackID: name == song.artistName ? song.sourceID : nil) {
                        await MainActor.run { onOpenArtist(a) }
                    }
                }
            },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: context) } },
            index: index
        )
    }

    private var albumsGrid: some View {
        let shown = albumsExpanded ? albums : Array(albums.prefix(collapsedAlbumCount))
        return VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Albums")
            LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 18) {
                ForEach(shown) { album in
                    IOSAlbumCard(album: album) { onOpenAlbum(album) }
                        .contextMenu { OnlineCollectionMenu(.album(album)) }
                }
            }
            if albums.count > collapsedAlbumCount {
                expandButton(expanded: $albumsExpanded)
            }
        }
    }

    /// Stand-in for Spotify's "Featuring <name>": two stations from the loaded catalogue. See `StationBuilder`.
    private var featuringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Playlists with \(artist.name)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(stations) { station in
                        MixMosaicCard(
                            mix: station,
                            isResolving: station.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
                            onOpen: {
                                if let onOpenMix { onOpenMix(station) }
                                else { DiscoverSessionStore.shared.path.append(.mix(station)) }
                            },
                            onPlay: {
                                guard let first = station.tracks.first else { return }
                                onPlay(first, station.tracks)
                            })
                    }
                }
                .padding(.bottom, 4)
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
            withMixAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
        } label: {
            Label(expanded.wrappedValue ? "Show less" : "Show more",
                  systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: MixFontScale.size(12), weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .buttonStyle(.plain).mixHandCursor()
        .padding(.top, 4)
    }

    private func load() async {
        loading = true
        let catalogue = await deps.itunesClient.artistCatalogue(for: artist)
        topTracks = catalogue.top
        albums    = catalogue.albums
        related   = catalogue.related
        stations  = StationBuilder.artistStations(artist, catalogue: catalogue)
        fanCount  = catalogue.fanCount
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
                        Text("Album").font(.system(size: MixFontScale.size(12), weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                        Text(album.title).font(.system(size: MixFontScale.size(24), weight: .bold))
                            .foregroundStyle(Color.mixTextPrimary).lineLimit(3)
                        TappableArtistRow(targets: ImportService.creditedArtists(from: album.artistName).map { name in
                            (name, {
                                Task {
                                    if let a = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                                        onOpenArtist(a)
                                    }
                                }
                            })
                        }, font: .system(size: MixFontScale.size(14)))
                        HStack(spacing: 10) {
                            AlbumSaveButton(title: album.title, artistName: album.artistName,
                                            onSave: { Task { await coordinator.addAlbumToLibrary(tracks) } })
                            AlbumDownloadButton(ids: tracks.map(\.stableTrackID), downloads: deps.downloadManager,
                                                library: deps.libraryService) {
                                SavedAlbumsService.shared.setSaved(true, title: album.title, artistName: album.artistName)
                                await coordinator.addAlbumToLibrary(tracks)
                            }
                            .disabled(tracks.isEmpty)
                            ShareHeroButton(.album(album))
                            // The card's long-press menu, for anyone who's already on the page.
                            Menu { OnlineCollectionMenu(.album(album), showsShare: false) } label: {
                                HeroCircleLabel(systemImage: "ellipsis")
                            }
                        }
                        .padding(.top, 2)
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
                            onOpenArtist: { name in
                                Task {
                                    if let a = await deps.itunesClient.resolveArtist(
                                        name: name,
                                        trackID: name == song.artistName ? song.sourceID : nil) {
                                        await MainActor.run { onOpenArtist(a) }
                                    }
                                }
                            },
                            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: tracks) } },
                            index: idx + 1
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(MixPageBackground())
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
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    } else if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.mixPrimary)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            HStack(spacing: 5) {
                Text(song.displayTitle)
                    .font(.mixLabel.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                if song.isExplicit { ExplicitBadge() }
            }
            Text(song.displayArtistName)
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Browse landing: genre tile

/// "Browse all" tile: hue by position, artwork tilted in the corner. Touch version of macOS `GenreTile`.
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
                .font(.system(size: MixFontScale.size(17), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(14)
            CachedRemoteImage(url: genre.pictureURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.clear }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .rotationEffect(.degrees(25))
                .offset(x: 18, y: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .clipped()
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
                        .font(.system(size: MixFontScale.size(14)))
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
        .background(MixPageBackground())
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
