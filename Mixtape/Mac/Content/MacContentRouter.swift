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
                HomeView { link in
                    switch link {
                    case .songs:     appState.selection = .songs
                    case .albums:    appState.selection = .albums
                    case .artists:   appState.selection = .artists
                    case .playlists: appState.selection = .playlists
                    }
                }
            case .songs:
                MacSongsView(searchText: appState.searchText)
            case .albums:
                MacAlbumsView(searchText: appState.searchText)
            case .artists:
                MacArtistsView(searchText: appState.searchText)
            case .playlists:
                MacPlaylistsView()
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

    let track: Track

    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var appState: MacAppState

    @State private var fileSize:   String = ""
    @State private var fileFormat: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                artworkHero
                    .padding(.bottom, 14)

                // Title / artist / album
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(track.artistName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixPrimary)
                        .lineLimit(1)
                    Text(track.albumTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                // Actions
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

                Divider().padding(.horizontal, 14)
                Button {
                    engine.queue.insertNext(track)
                    appState.closePanel()
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
