// MacContentRouter.swift
// Mixtape — Mac/Content
//
// Routes the sidebar selection → content view.
// When the search field is active (`appState.isSearching`), overrides the
// sidebar and shows MacSearchResultsView with unified Songs + Albums + Artists.
//
// The right-side inspector panel (Now Playing / Queue) lives at the MacRootView
// level, not here, so there is no .inspector modifier in this file.

#if os(macOS)
import SwiftUI

struct MacContentRouter: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var deps:     AppDependencies

    var body: some View {
        Group {
            contentBody
        }
        // Clear any album/playlist drill-down whenever the user switches sections.
        .onChange(of: appState.selection) { _, newValue in
            if newValue != nil {
                appState.selectedAlbum = nil
                appState.selectedPlaylist = nil
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if appState.isSearching {
            MacSearchResultsView(query: appState.searchText)
        } else if let album = appState.selectedAlbum {
            // Album drill-down: rendered flat here so sidebar clicks always work.
            // A NavigationStack inside a NavigationSplitView locks the detail column
            // to the pushed view, making sidebar items unresponsive.
            MacAlbumDetailView(album: album)
        } else if let playlist = appState.selectedPlaylist {
            PlaylistDetailView(playlist: playlist)
                .environmentObject(deps)
                .environmentObject(engine)
                .environmentObject(appState)
        } else {
            switch appState.selection ?? .home {
            case .home:
                HomeView(
                    onQuickLink: { link in
                        switch link {
                        case .songs:     appState.selection = .songs
                        case .albums:    appState.selection = .albums
                        case .artists:   appState.selection = .artists
                        case .playlists: appState.selection = .playlists
                        }
                    },
                    onPlay: { track, context in
                        // Route online (Discover) tracks through the coordinator;
                        // local tracks play on the offline engine.
                        Task {
                            if deps.onlineCoordinator.isStandaloneOnline(track) {
                                await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
                            } else {
                                await engine.play(track: track, in: context)
                            }
                        }
                    },
                    onArtist: { name in
                        // Prefer a matching library artist (artwork + albums);
                        // otherwise open the online artist page by name.
                        if let artist = library.artist(named: name) {
                            appState.showArtist(artist)
                        } else {
                            appState.showOnlineArtist(name: name, trackID: nil)
                        }
                    }
                )
            case .songs:
                MacSongsView(searchText: appState.searchText)
            case .albums:
                MacAlbumsView(searchText: appState.searchText)
            case .artists:
                MacArtistsView(searchText: appState.searchText)
            case .playlists:
                MacPlaylistsView()
            case .discover:
                OnlineDiscoverView()
                    .environmentObject(deps.onlineCoordinator)
            case .settings:
                SettingsView(
                    authService:    deps.authService,
                    syncService:    deps.syncService,
                    libraryService: deps.libraryService,
                    importService:  deps.importService
                )
            }
        }
    }
}

// MARK: - Track Inspector
//
// Internal (not private) so MacRightPanelView in MacRootView can use it.

struct MacTrackInspector: View {

    /// The track this panel was opened with — shown only as a fallback when
    /// nothing is playing. Per the "follow now-playing always" behaviour, the
    /// panel otherwise tracks the live current track (see `track`).
    let fallbackTrack: Track

    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var queue:    QueueService
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var appState: MacAppState

    @State private var fileSize:   String = ""
    @State private var fileFormat: String = ""

    /// Always reflects the currently playing track, falling back to whatever the
    /// panel was opened with when playback is stopped. Observing `queue` makes
    /// the whole panel re-render (and reload file metadata) on every song change.
    private var track: Track { queue.currentTrack ?? fallbackTrack }

    /// The library album matching the current track, if one exists.
    private var matchingAlbum: Album? {
        library.album(title: track.albumTitle, artistName: track.artistName)
    }

    /// The library artist matching the current track's artist, if one exists.
    private var matchingArtist: Artist? {
        library.artist(named: track.artistName)
    }

    /// True when the inspector's track is the one currently loaded in the queue.
    private var isCurrentTrack: Bool { queue.currentTrack?.id == track.id }

    /// Whether the inspector's track is in the user's Favourites. Reads through
    /// `library` so it re-evaluates whenever the library publishes a change.
    private var isFavourited: Bool { library.isFavourited(trackID: track.id) }

    /// True when the track isn't in the local library — i.e. an online Discover
    /// song that hasn't been saved offline. Its artist/album live online.
    private var isOnlineTrack: Bool { library.track(id: track.id) == nil }

    private var artistEnabled: Bool {
        isOnlineTrack ? !track.artistName.isEmpty : matchingArtist != nil
    }
    private var albumEnabled: Bool {
        isOnlineTrack ? !track.albumTitle.isEmpty : matchingAlbum != nil
    }

    private func openArtist() {
        if isOnlineTrack {
            appState.showOnlineArtist(name: track.artistName, trackID: nil)
        } else if let artist = matchingArtist {
            appState.showArtist(artist)
        }
    }
    /// Clicking the song title or album opens the album (local or Discover).
    private func openAlbum() {
        if isOnlineTrack {
            appState.showOnlineAlbum(title: track.albumTitle, artistName: track.artistName, trackID: nil)
        } else if let album = matchingAlbum {
            appState.showAlbum(album)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                artworkHero
                    .padding(.bottom, 14)

                // Title / artist / album — artist & album drill in when present.
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        InspectorLinkLine(text: track.title,
                                          color: Color.mixTextPrimary,
                                          enabled: albumEnabled,
                                          font: .system(size: 14, weight: .semibold),
                                          lineLimit: 3) { openAlbum() }

                        InspectorLinkLine(text: track.artistName,
                                          color: Color.mixPrimary,
                                          enabled: artistEnabled) { openArtist() }

                        InspectorLinkLine(text: track.albumTitle,
                                          color: Color.mixTextSecondary,
                                          enabled: albumEnabled) { openAlbum() }
                    }

                    Spacer(minLength: 0)

                    // Favourite toggle
                    Button {
                        _ = library.toggleFavourite(trackID: track.id)
                    } label: {
                        Image(systemName: isFavourited ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(isFavourited ? Color.mixPrimary : Color.mixTextTertiary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFavourited ? "Remove from Favourites" : "Add to Favourites")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                // Actions — when this track is already playing, the Play button is
                // pointless, so show a single full-width Queue button instead.
                Group {
                    if isCurrentTrack {
                        Button {
                            engine.queue.append(track)
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.mixPrimary)
                    } else {
                        HStack(spacing: 6) {
                            Button {
                                Task { await engine.play(track: track, in: library.tracks) }
                            } label: {
                                Label("Play Now", systemImage: "play.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.mixPrimary)

                            Button {
                                engine.queue.append(track)
                            } label: {
                                Label("Queue", systemImage: "text.badge.plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                Divider().padding(.horizontal, 14)

                // Metadata
                VStack(spacing: 0) {
                    inspectorRow("Duration", value: track.formattedDuration)
                    if let year = track.year            { inspectorRow("Year",     value: "\(year)") }
                    if let g = track.genre, !g.isEmpty  { inspectorRow("Genre",    value: g) }
                    if let tn = track.trackNumber       { inspectorRow("Track",    value: "\(tn)") }
                    if let dn = track.discNumber, dn > 1 { inspectorRow("Disc",   value: "\(dn)") }
                    if let c = track.composer, !c.isEmpty { inspectorRow("Composer", value: c) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // File info
                if !fileFormat.isEmpty || !fileSize.isEmpty {
                    Divider().padding(.horizontal, 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("FILE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.mixTextTertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        VStack(spacing: 0) {
                            if !fileFormat.isEmpty { inspectorRow("Format", value: fileFormat) }
                            if !fileSize.isEmpty   { inspectorRow("Size",   value: fileSize)   }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                }

                // "Play Next" queues the track right after the current one. Hidden
                // for the now-playing track, where it would just duplicate it.
                if !isCurrentTrack {
                    Divider().padding(.horizontal, 14)
                    Button {
                        engine.queue.insertNext(track)
                    } label: {
                        HStack {
                            Image(systemName: "text.insert").frame(width: 16)
                            Text("Play Next")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color.mixBackground)
        .onAppear  { loadFileMetadata() }
        .onChange(of: track.id) { _, _ in loadFileMetadata() }
    }

    private var artworkHero: some View {
        Group {
            if let data = track.artworkData, let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.mixSurface)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private func inspectorRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 60, alignment: .leading)
                .padding(.vertical, 3)
            Text(value)
                .font(.caption)
                .foregroundStyle(Color.mixTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
            Spacer()
        }
    }

    private func loadFileMetadata() {
        let path = track.file.localPath
        let ext  = URL(fileURLWithPath: path).pathExtension.uppercased()
        fileFormat = ext.isEmpty ? "Audio" : ext
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
}

// MARK: - Inspector Link Line
//
// A single artist/album line under the title. When a navigation target exists
// it behaves as a borderless button with a pointing-hand cursor and a hover
// underline (Spotify-style); otherwise it renders as plain text.

private struct InspectorLinkLine: View {
    let text:    String
    let color:   Color
    let enabled: Bool
    var font:    Font = .system(size: 12)
    var lineLimit: Int = 1
    let action:  () -> Void

    @State private var isHovered = false

    var body: some View {
        if enabled {
            Button(action: action) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .underline(isHovered)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                isHovered = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Inspector Row (shared)

struct MacInspectorRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Color.mixTextSecondary).frame(width: 64, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(Color.mixTextPrimary)
            Spacer()
        }
    }
}

#endif
