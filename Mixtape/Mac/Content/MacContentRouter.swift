// Routes the sidebar selection to a content view. A committed search (`appState.isSearching`)
// overrides it with Discover, which pins library matches above the catalogue results.
// The right panel lives in MacRootView.

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
        // Switching sections clears any album/playlist/profile/account drill-down.
        .onChange(of: appState.selection) { _, newValue in
            if newValue != nil {
                appState.selectedAlbum = nil
                appState.selectedPlaylist = nil
                appState.showingAccount = false
                appState.profileTarget = nil
                appState.publicPlaylistTarget = nil
                appState.messagesPage = nil
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if appState.showingAccount {
            MacAccountPage()
        } else if let target = appState.publicPlaylistTarget {
            // Drawn over the profile, which is where Back returns.
            MacPublicPlaylistPage(target: target)
        } else if let page = appState.messagesPage {
            MacMessagesPage(page: page)
        } else if let profile = appState.profileTarget {
            MacProfilePage(profile: profile)
        } else if appState.isSearching {
            // Every search lands in Discover, library matches included.
            OnlineDiscoverView()
                .environmentObject(deps.onlineCoordinator)
        } else if appState.discoverLinkActive {
            // A Discover page opened from a name link. Above the drill-downs so Back returns to them,
            // below search so typing still takes the column.
            OnlineDiscoverView()
                .environmentObject(deps.onlineCoordinator)
        } else if let album = appState.selectedAlbum {
            // Drill-downs render flat: a NavigationStack in the detail column made sidebar clicks unresponsive.
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
        } else if let crateID = appState.selectedCrateID {
            CrateDetailView(crateID: crateID, library: library)
        } else {
            switch appState.selection ?? .home {
            case .home, .discover:
                // Home and Discover are tabs of one landing page; the `.onChange` below picks the tab.
                OnlineDiscoverView()
                    .environmentObject(deps.onlineCoordinator)
            case .library, .songs, .albums, .artists, .playlists:
                // The old sections open as tabs of the Library page.
                MacLibraryView()
            case .localFiles:
                LocalFilesPage()
            case .community:
                CommunityView(onOpenPost: { appState.showPost(code: $0) },
                              onOpenProfile: { appState.showProfile($0) })
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
// Settings > Manage Account, rendered flat like the drill-downs. Back returns to Settings.

struct MacAccountPage: View {

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        AccountSettingsView()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            // Clears the floating back control.
            .padding(.top, 50)
            .background(MixPageBackground())
            .pageBack("Settings") {
                appState.goToSection(.settings)
            }
    }
}

// MARK: - Profile Page
// Someone's profile, rendered flat across the content area.

struct MacProfilePage: View {

    let profile: UserProfile

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        ProfilePageView(profile: profile)
            .background(MixPageBackground())
            .pageBack { appState.profileTarget = nil }
    }
}

// MARK: - Public Playlist Page
// Someone's public playlist, opened from their profile. Rendered flat like the pages above.

struct MacPublicPlaylistPage: View {

    let target: PublicPlaylistTarget

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        PublicPlaylistPage(summary: target.summary, ownerName: target.ownerName)
            .background(MixPageBackground())
            // Named, since this stack is two deep.
            .pageBack("@\(target.ownerName)") { appState.publicPlaylistTarget = nil }
    }
}

// MARK: - Messages Page
// Conversations on the left, the open one (or New message) on the right.

struct MacMessagesPage: View {

    let page: MacAppState.MessagesPage

    @EnvironmentObject private var appState: MacAppState
    @State private var picking = false

    private var person: UserProfile? {
        if case .thread(let person) = page { person } else { nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            MessagesView(selected: picking ? nil : person?.id,
                         open: { picking = false; appState.messagesPage = .thread($0) },
                         compose: { picking = true })
                .frame(width: 320)
            Rectangle().fill(Color.mixSeparator).frame(width: 0.5)
            Group {
                if picking {
                    NewMessagePicker(back: { picking = false }) {
                        picking = false
                        appState.messagesPage = .thread($0)
                    }
                } else if let person {
                    MessageThreadView(person: person, openProfile: { appState.showProfile(person) })
                        // Identity, so switching conversations starts a fresh thread.
                        .id(person.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MixPageBackground())
        .pageBack { appState.messagesPage = nil }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "paperplane")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.mixTextTertiary)
            Text("Your messages")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Send songs, photos and stickers to a friend.")
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary)
            Button { picking = true } label: {
                Text("New message")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.mixAccentFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .mixHandCursor()
            .padding(.top, 6)
        }
    }
}

// MARK: - Track Inspector
//
// Internal (not private) so MacRightPanelView in MacRootView can use it.

struct MacTrackInspector: View {

    /// Shown only when nothing is playing; otherwise the panel follows the current track.
    let fallbackTrack: Track

    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var queue:    QueueService
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    @State private var fileSize:   String = ""
    @State private var fileFormat: String = ""

    /// The playing track, or the one the panel opened with when stopped.
    private var track: Track { queue.currentTrack ?? fallbackTrack }


    /// True when the inspector's track is the one currently loaded in the queue.
    private var isCurrentTrack: Bool { queue.currentTrack?.id == track.id }

    /// Reads through `library` so it updates when the library publishes.
    private var isFavourited: Bool { library.isFavourited(trackID: track.id) }

    private var albumEnabled: Bool { !track.albumTitle.isEmpty }

    /// One target per artist plus the album, from `TrackLinks`: always Discover, never the library row.
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

                // Title / artist / album; artist and album link when available.
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

                // For the playing track, Play is pointless, so show one full-width Queue button.
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

                // Hidden for the playing track.
                if !isCurrentTrack {
                    InspectorActionButton(title: "Play Next",
                                          icon: "text.insert",
                                          fullWidth: true) {
                        engine.queue.insertNext(track)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }

                // What plays next, with a way into the full queue.
                upNextRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)

                // Metadata as one card.
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
        // Transparent: the column paints the window colour and wash behind it.
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

    /// One card: header with an "Open queue" link, then the next song with its cover.
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
        // Inset and rounded so the cover doesn't read as a banner.
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
        // `localPath` is Documents-relative; resolve it (with export/cache fallbacks) before statting.
        let resolved = deps.fileStorage.localURL(for: track)
        let ext = (resolved?.pathExtension ?? URL(fileURLWithPath: track.file.localPath).pathExtension).uppercased()
        fileFormat = ext.isEmpty ? "Audio" : ext
        fileSize = ""
        if let resolved,
           let bytes = (try? FileManager.default.attributesOfItem(atPath: resolved.path(percentEncoded: false)))?[.size] as? Int64 {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else if track.file.fileSize > 0 {
            // No local copy: fall back to the size recorded at import.
            fileSize = ByteCountFormatter.string(fromByteCount: track.file.fileSize, countStyle: .file)
        }
    }
}

// MARK: - Inspector Action Button
// Capsule buttons for the inspector's Play / Queue / Play Next row, matching the album and mix pages.

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
// An artist/album line under the title: a hover-underlined link with a target, plain text without.

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
// One or more clickable artist names, comma-separated, so each credit opens its own page.

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
                // See `TappableArtistRow`: the credit truncates once at the end.
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
