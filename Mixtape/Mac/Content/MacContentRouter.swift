// MacContentRouter.swift
// Mixtape — Mac/Content
//
// Routes the sidebar selection → content view.
// When the search field is active (`appState.isSearching`), overrides the
// sidebar and shows Discover, which searches the catalogue and pins your own
// matching library songs above the results. "Active" means a query the user
// has actually asked for — Return, or a picked suggestion. Typing alone gets
// the panel under the search field and nothing else, and navigating away leaves
// the text in the field without letting it claim the column, so the page you
// clicked is the page you get. See `MacAppState.searchCommitted`.
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
        // Clear any album/playlist/profile/account drill-down whenever the user
        // switches sections.
        .onChange(of: appState.selection) { _, newValue in
            // Selecting one of the four old sections means "open the Library page
            // on that tab". Done here rather than at each call site so nothing
            // that already knew how to navigate to Songs had to learn a new way.
            if let tab = newValue?.libraryTab { appState.libraryTab = tab }

            if newValue != nil {
                appState.selectedAlbum = nil
                appState.selectedPlaylist = nil
                appState.showingAccount = false
                appState.profileTarget = nil
                appState.publicPlaylistTarget = nil
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if appState.showingAccount {
            MacAccountPage()
        } else if let target = appState.publicPlaylistTarget {
            // Above the profile, not instead of it — the profile underneath is
            // still the thing Back returns to.
            MacPublicPlaylistPage(target: target)
        } else if let profile = appState.profileTarget {
            MacProfilePage(profile: profile)
        } else if appState.isSearching, !appState.searchInLibrary {
            // Every search lands in Discover, whatever section you started
            // typing in. Discover puts your own matching songs above the online
            // ones, so this is a superset of what the old library-only results
            // page could show — and the only way to reach a song you don't
            // already own. `searchInLibrary` is the deliberate exception: it's
            // set by Discover's own "Show all in Library", so the query falls
            // through to the Library page below.
            OnlineDiscoverView()
                .environmentObject(deps.onlineCoordinator)
        } else if appState.discoverLinkActive {
            // An artist or album opened by clicking a name somewhere else in the
            // window. Above the album/playlist drill-downs, because a name
            // clicked *on* an album page opens over it and Back returns to it —
            // and deliberately below the search branch, so typing still takes
            // the column the way it does everywhere else.
            OnlineDiscoverView()
                .environmentObject(deps.onlineCoordinator)
        } else if let album = appState.selectedAlbum {
            // Album drill-down: rendered flat here so sidebar clicks always work.
            // A NavigationStack inside a NavigationSplitView locks the detail column
            // to the pushed view, making sidebar items unresponsive.
            MacAlbumDetailView(album: album)
        } else if let smart = appState.selectedSmartPlaylist {
            SmartPlaylistDetailView(playlist: smart, service: deps.smartPlaylistService)
                .environmentObject(deps)
                .environmentObject(engine)
                .environmentObject(appState)
        } else if let playlist = appState.selectedPlaylist {
            PlaylistDetailView(playlist: playlist)
                .environmentObject(deps)
                .environmentObject(engine)
                .environmentObject(appState)
        } else {
            switch appState.selection ?? .home {
            case .home, .discover:
                // One destination now. Home knew your library but nothing about
                // the catalogue; Discover knew the catalogue but nothing about
                // you — and neither was a complete front door. They're tabs of
                // the same landing page, and both selections still resolve, so
                // deep links, the command palette and restored state all keep
                // working; the `.onChange` below just picks the opening tab.
                OnlineDiscoverView()
                    .environmentObject(deps.onlineCoordinator)
            case .library, .songs, .albums, .artists, .playlists:
                // The four old sections are tab identities now. Selecting one
                // still means "open that view", it just opens as a tab of the
                // Library page — so every existing navigation into them keeps
                // working without any of their call sites changing.
                MacLibraryView()
            case .localFiles:
                LocalFilesPage()
            case .settings:
                SettingsView(
                    authService:    deps.authService,
                    syncService:    deps.syncService,
                    libraryService: deps.libraryService,
                    importService:  deps.importService,
                    statsService:   deps.statsService,
                    profileStats:   deps.profileStatsService,
                    downloadManager: deps.downloadManager
                )
            }
        }
    }
}

// MARK: - Account Page (inline, full content area)
//
// Reached from Settings → "Manage Account". Rendered flat by MacContentRouter
// (like the album/playlist drill-downs) rather than as a sheet, so it feels
// like a real destination and the sidebar stays responsive. The Back button
// returns to Settings. Presentation ported from main's 1.1 Account window; the
// content is the shared (newer) AccountSettingsView.

struct MacAccountPage: View {

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        AccountSettingsView()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            // Clears the floating back control.
            .padding(.top, 50)
            .background(Color.mixBackground)
            .pageBack("Settings") {
                appState.goToSection(.settings)
            }
    }
}

// MARK: - Profile Page
//
// Someone's profile, rendered flat across the content area like the album and
// playlist drill-downs — sidebar clicks keep working, and the page gets the full
// width it was designed for instead of a sheet's worth.

struct MacProfilePage: View {

    let profile: UserProfile

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        ProfilePageView(profile: profile)
            .background(Color.mixBackground)
            .pageBack { appState.profileTarget = nil }
    }
}

// MARK: - Public Playlist Page
//
// Someone else's public playlist, opened from their profile. Same flat
// treatment as the pages above — it used to be a 460×520 sheet, which meant the
// one place you look at a *playlist* was the one place that didn't look like
// the playlist screen.

struct MacPublicPlaylistPage: View {

    let target: PublicPlaylistTarget

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        PublicPlaylistPage(summary: target.summary, ownerName: target.ownerName)
            .background(Color.mixBackground)
            // Named, because this is a two-deep stack and "Back" alone doesn't
            // say which of the two it unwinds.
            .pageBack("@\(target.ownerName)") { appState.publicPlaylistTarget = nil }
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
    @EnvironmentObject private var deps:     AppDependencies

    @State private var fileSize:   String = ""
    @State private var fileFormat: String = ""

    /// Always reflects the currently playing track, falling back to whatever the
    /// panel was opened with when playback is stopped. Observing `queue` makes
    /// the whole panel re-render (and reload file metadata) on every song change.
    private var track: Track { queue.currentTrack ?? fallbackTrack }


    /// True when the inspector's track is the one currently loaded in the queue.
    private var isCurrentTrack: Bool { queue.currentTrack?.id == track.id }

    /// Whether the inspector's track is in the user's Favourites. Reads through
    /// `library` so it re-evaluates whenever the library publishes a change.
    private var isFavourited: Bool { library.isFavourited(trackID: track.id) }

    private var albumEnabled: Bool { !track.albumTitle.isEmpty }

    /// One tappable target per individual artist on the track, and the title's
    /// album target. Both come from `TrackLinks`, so the inspector answers the
    /// same question the player bar, the queue and the lyrics header do — and
    /// answers it the same way: Discover, never the local library row.
    private var artistTargets: [(name: String, action: () -> Void)] {
        TrackLinks.artists(for: track, appState: appState)
    }

    private func openAlbum() { appState.openDiscoverAlbum(for: track) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                artworkHero
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                // Title / artist / album — artist & album drill in when present.
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        InspectorLinkLine(text: track.title,
                                          color: Color.mixTextPrimary,
                                          enabled: albumEnabled,
                                          font: .system(size: 16, weight: .semibold),
                                          lineLimit: 3) { openAlbum() }

                        InspectorArtistLine(targets: artistTargets, color: Color.mixPrimary)

                        InspectorLinkLine(text: track.albumTitle,
                                          color: Color.mixTextSecondary,
                                          enabled: albumEnabled,
                                          font: .system(size: 11)) { openAlbum() }
                    }

                    Spacer(minLength: 0)

                    // Favourite toggle
                    Button {
                        deps.toggleFavourite(trackID: track.id)
                    } label: {
                        Image(systemName: isFavourited ? "heart.fill" : "heart")
                            .font(.system(size: 14))
                            .foregroundStyle(isFavourited ? Color.mixPrimary : Color.mixTextTertiary)
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .help(isFavourited ? "Remove from Liked Songs" : "Add to Liked Songs")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                // Actions — when this track is already playing, the Play button is
                // pointless, so show a single full-width Queue button instead.
                HStack(spacing: 8) {
                    if !isCurrentTrack {
                        InspectorActionButton(title: "Play", icon: "play.fill", prominent: true) {
                            Task { await engine.play(track: track, in: library.tracks, source: .named("Songs")) }
                        }
                        InspectorActionButton(title: "Queue", icon: "text.badge.plus") {
                            engine.queue.append(track)
                        }
                    } else {
                        InspectorActionButton(title: "Add to Queue",
                                              icon: "text.badge.plus",
                                              prominent: true) {
                            engine.queue.append(track)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

                // "Play Next" queues the track right after the current one. Hidden
                // for the now-playing track, where it would just duplicate it.
                if !isCurrentTrack {
                    InspectorActionButton(title: "Play Next",
                                          icon: "text.insert",
                                          fullWidth: true) {
                        engine.queue.insertNext(track)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }

                // What plays after this one, and the way through to the rest of
                // it. Both live here because "what's next?" is the question this
                // panel is open to answer, and the only previous answer was to
                // leave for the Queue tab and lose the song you were looking at.
                upNextRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)

                // Metadata — one card rather than a run of hairlines, so the
                // details read as a block and the wash keeps coming through
                // around it.
                inspectorCard("Details") {
                    inspectorRow("Duration", value: track.formattedDuration)
                    if let year = track.year             { inspectorRow("Year",     value: "\(year)") }
                    if let g = track.genre, !g.isEmpty   { inspectorRow("Genre",    value: g) }
                    if let tn = track.trackNumber        { inspectorRow("Track",    value: "\(tn)") }
                    if let dn = track.discNumber, dn > 1 { inspectorRow("Disc",     value: "\(dn)") }
                    if let c = track.composer, !c.isEmpty { inspectorRow("Composer", value: c) }
                }
                .padding(.horizontal, 14)

                if !fileFormat.isEmpty || !fileSize.isEmpty {
                    inspectorCard("File") {
                        if !fileFormat.isEmpty { inspectorRow("Format", value: fileFormat) }
                        if !fileSize.isEmpty   { inspectorRow("Size",   value: fileSize)   }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }
            }
            .padding(.bottom, 18)
        }
        // Like the Queue panel: the right-hand column paints the window colour
        // and the page's wash behind this, so it stays transparent.
        .onAppear  { loadFileMetadata() }
        .onChange(of: track.id) { _, _ in loadFileMetadata() }
    }

    /// The song after this one in the queue, if there is one.
    private var nextInQueue: Track? {
        let rows  = queue.entries
        let index = queue.currentIndex + 1
        guard rows.indices.contains(index) else { return nil }
        return rows[index].track
    }

    /// One card, not two: a header line that says what this is with the way
    /// into the full queue sitting opposite it, and the next song itself
    /// underneath with its cover. Two equal plates side by side made "Open
    /// queue" look like a second song and squeezed the title to nothing.
    private var upNextRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Next in queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button { appState.showPanel(.queue) } label: {
                    Text("Open queue")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Show everything that's queued")
            }

            if let next = nextInQueue {
                Button {
                    Task { await engine.playNext() }
                } label: {
                    HStack(spacing: 10) {
                        MacArtworkView(data: next.artworkData, artworkRef: .track(next.id), size: 40, cornerRadius: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.mixTextPrimary)
                                .lineLimit(1)
                            Text(next.artistName)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mixTextSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Skip to \u{201C}\(next.title)\u{201D}")
            } else {
                Text("Nothing queued after this song")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var artworkHero: some View {
        Group {
            if let data = track.displayArtwork, let nsImg = NSImage(data: data) {
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
        // Inset and rounded rather than edge-to-edge: the cover reads as the
        // panel's subject instead of as a banner welded to the window edge.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .mixShadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    /// A titled group of detail rows on a soft plate.
    private func inspectorCard<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)

            VStack(spacing: 0) { content() }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func inspectorRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 62, alignment: .leading)
                .padding(.vertical, 4)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
    }

    private func loadFileMetadata() {
        // localPath is Documents-relative — resolve to a real on-disk URL
        // (export folder / cache fallbacks included) before statting it, or the
        // Size row never populates.
        let resolved = deps.fileStorage.localURL(for: track)
        let ext = (resolved?.pathExtension ?? URL(fileURLWithPath: track.file.localPath).pathExtension).uppercased()
        fileFormat = ext.isEmpty ? "Audio" : ext
        fileSize = ""
        if let resolved,
           let bytes = (try? FileManager.default.attributesOfItem(atPath: resolved.path(percentEncoded: false)))?[.size] as? Int64 {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else if track.file.fileSize > 0 {
            // No local copy (e.g. not yet downloaded on this device) — fall back
            // to the size recorded at import.
            fileSize = ByteCountFormatter.string(fromByteCount: track.file.fileSize, countStyle: .file)
        }
    }
}

// MARK: - Inspector Action Button
//
// Capsule actions for the inspector's Play / Queue / Play Next row. The stock
// bordered buttons were the one part of the panel that still looked like a
// system dialog; these match the pill controls used on album and mix pages.

private struct InspectorActionButton: View {
    let title:     String
    let icon:      String
    var prominent: Bool = false
    var fullWidth: Bool = false
    let action:    () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? .black : Color.mixTextPrimary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(fill, in: Capsule())
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(Color.primary.opacity(isHovered ? 0.22 : 0.14),
                                           lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(isHovered ? 1.02 : 1)
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fill: Color {
        if prominent { return Color.mixPrimary.opacity(isHovered ? 0.9 : 1) }
        return Color.primary.opacity(isHovered ? 0.08 : 0.04)
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
            .buttonStyle(.plain).mixHandCursor()
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

// MARK: - InspectorArtistLine
//
// Renders one or more individually-tappable artist names, comma-separated. A
// single artist matches a lone InspectorLinkLine; multiple artists (a "feat."
// blob) each become their own click-through target so the correct profile opens.

private struct InspectorArtistLine: View {
    let targets: [(name: String, action: () -> Void)]
    let color:   Color

    var body: some View {
        if targets.count <= 1 {
            InspectorLinkLine(text:    targets.first?.name ?? "",
                              color:   color,
                              enabled: targets.first != nil) {
                targets.first?.action()
            }
        } else {
            // Wrap to multiple lines when many features don't fit one row.
            FlowArtistRow(targets: targets, color: color)
        }
    }
}

/// Comma-separated, wrapping row of tappable artist names.
private struct FlowArtistRow: View {
    let targets: [(name: String, action: () -> Void)]
    let color:   Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.offset) { idx, item in
                // See `TappableArtistRow` — the credit trails off once at the
                // end instead of every name giving up letters at once.
                InspectorLinkLine(text: item.name, color: color, enabled: true) {
                    item.action()
                }
                .layoutPriority(Double(targets.count - idx))
                if idx < targets.count - 1 {
                    Text(", ")
                        .font(.system(size: 12))
                        .foregroundStyle(color)
                        .fixedSize()
                        .layoutPriority(Double(targets.count - idx))
                }
            }
            Spacer(minLength: 0)
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
