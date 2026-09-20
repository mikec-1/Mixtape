// ProfilePageView.swift
// Mixtape — Features/Social
//
// A user's profile, as a real page rather than a sheet — yours or anyone
// else's, same view.
//
// The shape is the familiar one: a hero band with a large round avatar and the
// handle set big, a stat line under it, a row of top artists, then the public
// playlists. What's deliberately NOT here is a follower count. Mixtape has no
// follow graph, and a "0 Followers" that can never become 1 is worse than an
// honest gap — the stat line shows only numbers that mean something today.
//
// Own profile vs. someone else's is one view because the content is the same
// content; the difference is that you get told what other people can see (the
// "Only visible to you" note when stats sharing is off, and the reminder that
// private playlists are hidden) and a way to change it.

import SwiftUI

public struct ProfilePageView: View {

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    private let profile: UserProfile

    @State private var stats: PublicProfileStats?
    @State private var playlists: [PublicPlaylistSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showingAllPlaylists = false
    /// iOS only — macOS routes through MacAppState so the playlist gets the whole
    /// content column instead of a push inside whatever presented this page.
    @State private var openPlaylist: PublicPlaylistSummary?

    /// The context menu's state. Held per-summary rather than as booleans so the
    /// menu can act on any card in the grid without a selection concept.
    @State private var manageCollaborators: PublicPlaylistSummary?
    @State private var pendingDelete: PublicPlaylistSummary?
    @State private var editingPlaylist: Playlist?
    @State private var actionError: String?
    /// Cards with a request in flight. Stops a second Delete landing on a row the
    /// first one is already removing.
    @State private var busyIDs: Set<UUID> = []

    /// The pictures this page draws. None of them are published; see
    /// ProfileArtwork.swift for where they actually come from.
    @StateObject private var artwork = ProfileArtworkStore()

    public init(profile: UserProfile) {
        self.profile = profile
    }

    private var isMe: Bool { deps.authService.currentUser?.id == profile.id }

    /// Six fills two rows of the grid at most window widths — enough to show the
    /// collection has depth without the page becoming a playlist browser.
    private static let collapsedPlaylistCount = 6

    private var visiblePlaylists: [PublicPlaylistSummary] {
        showingAllPlaylists ? playlists : Array(playlists.prefix(Self.collapsedPlaylistCount))
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header

                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Color.mixPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    if let stats, !stats.topArtists.isEmpty {
                        topArtistsSection(stats.topArtists)
                    }
                    playlistsSection
                    if isLoading == false, stats?.hasData != true, playlists.isEmpty {
                        emptyState
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.pageInset)
            .padding(.bottom, 48)
        }
        // Same wash every other detail page wears, for the same reason: applied
        // out here it spans the whole window and runs up into the chrome, where
        // the hand-rolled gradient this replaced was pinned inside the header's
        // own 1000pt-capped column and stopped dead at its edges.
        .artworkWash(source: artwork.avatar, fallback: ArtworkColors.brandGradient)
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        // Pushed, not presented: this page always lives inside a NavigationStack
        // on iOS, and a playlist opened from a profile is a place you go and come
        // back from — the sheet it used to be had its own cramped 460pt world.
        .navigationDestination(item: $openPlaylist) { summary in
            PublicPlaylistPage(summary: summary, ownerName: profile.name)
                .environmentObject(deps)
        }
        #endif
        .sheet(item: $manageCollaborators) { summary in
            InviteCollaboratorsSheet(sharedPlaylistID: summary.id,
                                     localPlaylistID: localPlaylist(for: summary)?.id,
                                     name: summary.name,
                                     coverData: coverData(for: summary),
                                     // Only reachable from `isMe`, and the rows on
                                     // this page were fetched by owner id.
                                     isOwner: true)
                .environmentObject(deps)
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorSheet(editingPlaylist: playlist)
                .environmentObject(deps)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { summary in
            Button("Delete", role: .destructive) { Task { await deletePlaylist(summary) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { summary in
            Text(deleteMessage(for: summary))
        }
        .alert("Couldn't do that",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task(id: profile.id) { await load() }
    }

    // MARK: - Header

    /// The hero band. The colour behind it isn't painted here — see the
    /// `artworkWash` on the body, which has to sit outside this column to reach
    /// the window's edges.
    private var header: some View {
        HStack(alignment: .bottom, spacing: Metrics.headerSpacing) {
            AvatarView(url: profile.avatarURL,
                       fallbackText: profile.username,
                       size: Metrics.avatar)
                .mixShadow(color: .black.opacity(0.35), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Profile")
                    .font(.mixCaptionBold)
                    .tracking(0.7)
                    .foregroundStyle(Color.mixTextSecondary)

                Text(profile.name)
                    .font(Metrics.nameFont)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .mixTightened()

                statLine
            }
            .padding(.bottom, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.headerTop)
        .padding(.bottom, 8)
    }

    /// Only counts that exist. Playlists are always true; plays come from
    /// published stats and drop out when someone has sharing off.
    private var statLine: some View {
        let parts: [String] = {
            var out = ["@\(profile.username)", pluralised(playlists.count, "Public Playlist")]
            if let stats, stats.shared, stats.hasData {
                out.append(pluralised(stats.totalPlays, "Play"))
            }
            return out
        }()

        return Text(parts.joined(separator: " · "))
            .font(.mixSubtext)
            .foregroundStyle(Color.mixTextSecondary)
    }

    // MARK: - Top artists

    private func topArtistsSection(_ artists: [PublicProfileStats.ArtistEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Top artists")
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)

                // Spotify's own wording, and it earns its place: without it you
                // can't tell whether you're looking at a public boast or a
                // private readout.
                if isMe {
                    Text(deps.profileStatsService.isSharingEnabled
                         ? "Visible on your profile"
                         : "Only visible to you")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(artists.prefix(8)) { artist in
                        ArtistCircle(name: artist.name,
                                     plays: artist.plays,
                                     photo: artwork.artistImages[artist.name]) {
                            openArtist(artist.name)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Public playlists

    @ViewBuilder
    private var playlistsSection: some View {
        if playlists.isEmpty {
            if isMe {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Public Playlists")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)

                    HintCard(
                        icon: "eye.slash",
                        title: "Nothing public yet",
                        message: "Your playlists are private until you say otherwise. Open one and turn on “Show on my profile” to put it here."
                    )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Public Playlists")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)

                    Spacer(minLength: 12)

                    if playlists.count > Self.collapsedPlaylistCount {
                        Button(showingAllPlaylists ? "Show less" : "Show all") {
                            withMixAnimation(.easeOut(duration: 0.18)) {
                                showingAllPlaylists.toggle()
                            }
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.mixCaptionBold)
                        .tracking(0.4)
                        .foregroundStyle(Color.mixTextSecondary)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.cardMin,
                                                       maximum: Metrics.cardMax),
                                             spacing: 16, alignment: .top)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(visiblePlaylists) { summary in
                        let card = Button { open(summary) } label: {
                            PublicPlaylistCard(summary: summary,
                                               cover: artwork.playlistCovers[summary.id])
                        }
                        .buttonStyle(.plain).mixHandCursor()

                        // Only on your own profile: everything in this menu is an
                        // owner action, and an empty `.contextMenu` on someone
                        // else's page would still eat the long-press on iOS.
                        if isMe {
                            card.contextMenu { playlistMenu(summary) }
                        } else {
                            card.contextMenu {
                                ShareMenuItems(.playlist(summary))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Right-click on macOS, long-press on iOS — the same menu, because these are
    /// the same actions the playlist's own "…" offers.
    ///
    /// It exists because that "…" isn't always reachable. Every removal path in
    /// the playlist page runs through the local `Playlist`, so a published row
    /// whose local copy is gone — library cleared, app reinstalled, account
    /// switched — had nowhere to be deleted from. It sat on the profile offering
    /// only to restore the thing you were trying to get rid of. The two service
    /// calls below address the shared row by id and need no local copy at all.
    @ViewBuilder
    private func playlistMenu(_ summary: PublicPlaylistSummary) -> some View {
        let local = localPlaylist(for: summary)

        Button { open(summary) } label: {
            Label("Open", systemImage: "rectangle.portrait.and.arrow.right")
        }

        Divider()

        // Already public, so the link works as it stands.
        ShareMenuItems(.playlist(summary))

        Divider()

        // The invite screen is the only place a code or a link is handed out.
        // It used to be copyable straight from here too, which meant two routes
        // to the same secret that could disagree about what it currently is.
        Button { manageCollaborators = summary } label: {
            Label("Manage Collaborators", systemImage: "person.2")
        }

        // Editing needs the real playlist — the published row is a snapshot, and
        // renaming that would leave the library disagreeing with the profile.
        if let local {
            Divider()
            Button { editingPlaylist = local } label: {
                Label("Edit Details", systemImage: "pencil")
            }
        }

        Divider()

        Button { Task { await makePrivate(summary) } } label: {
            Label("Make Private", systemImage: "eye.slash")
        }

        Button(role: .destructive) { pendingDelete = summary } label: {
            Label(local == nil ? "Delete from Profile" : "Delete Playlist",
                  systemImage: "trash")
        }
    }

    // MARK: - Empty / error

    private var emptyState: some View {
        HintCard(
            icon: loadFailed ? "wifi.exclamationmark" : "waveform",
            title: loadFailed ? "Couldn't load this profile" : "Nothing here yet",
            message: loadFailed
                ? "Check your connection and try again."
                : "\(isMe ? "You haven't" : "@\(profile.username) hasn't") made anything public."
        )
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadFailed = false

        // Detached from the two fetches below and never awaited with them: the
        // wash is the first thing anyone sees, and holding it behind the stats
        // request would leave the page grey for the whole round trip and then
        // flash into colour once the numbers happen to land.
        Task { await artwork.resolveAvatar(profile.avatarURL) }

        async let s = deps.profileStatsService.fetchStats(for: profile.id)
        async let p = deps.profileStatsService.fetchPublicPlaylists(for: profile.id)

        // The two halves fail independently: stats being unavailable shouldn't
        // wipe out the playlists, and vice versa. Only a total miss is an error.
        let loadedStats     = try? await s
        let loadedPlaylists = try? await p

        stats     = loadedStats ?? nil
        playlists = loadedPlaylists ?? []
        loadFailed = loadedStats == nil && loadedPlaylists == nil
        isLoading  = false

        // Only now: the names and counts are already on screen, and the pictures
        // come from the local library and the catalogue rather than from the two
        // requests above. Resolving them before dropping the spinner would hold
        // the whole page behind a lookup for a photo.
        await resolveArtwork()

        // Your own profile is the one place a missing published cover can be
        // repaired — it's the only device that holds the image. Costs nothing on
        // a profile whose covers are already up.
        if isMe {
            let repaired = await PlaylistSharingService.shared.backfillPublishedCovers(
                playlists, library: deps.libraryService
            )
            if !repaired.isEmpty {
                playlists = (try? await deps.profileStatsService.fetchPublicPlaylists(for: profile.id)) ?? playlists
            }
        }
    }

    private func resolveArtwork() async {
        let names = stats?.topArtists.prefix(8).map(\.name) ?? []
        let rows  = playlists
        async let artists: Void = artwork.resolveArtists(names,
                                                         library: deps.libraryService,
                                                         spotify: deps.spotifyClient)
        async let covers: Void = artwork.resolveCovers(rows,
                                                       library: deps.libraryService,
                                                       catalogue: deps.itunesClient)
        _ = await (artists, covers)
    }

    /// A public playlist is a full page on both platforms — the content column on
    /// macOS, a push on iOS.
    private func open(_ summary: PublicPlaylistSummary) {
        #if os(macOS)
        appState.showPublicPlaylist(summary, ownerName: profile.name)
        #else
        openPlaylist = summary
        #endif
    }

    // MARK: - Playlist actions

    /// The local playlist behind a published row, if this device still has one.
    ///
    /// Two lookups because the id can be either: the owner's own row carries its
    /// local `playlistID`, and a playlist that arrived here as a share is linked
    /// the other way round. Both miss on a device that no longer holds the
    /// playlist, which is the case the menu is here for.
    private func localPlaylist(for summary: PublicPlaylistSummary) -> Playlist? {
        if let mine = deps.libraryService.playlist(id: summary.playlistID) { return mine }
        if let localID = PlaylistSharingService.shared.localPlaylistID(forSharedPlaylist: summary.id) {
            return deps.libraryService.playlist(id: localID)
        }
        return nil
    }

    /// The cover the grid already drew, when it came from local data — the sheet
    /// shows it rather than fetching its own.
    private func coverData(for summary: PublicPlaylistSummary) -> Data? {
        if case .data(let bytes) = artwork.playlistCovers[summary.id] { return bytes }
        return nil
    }

    /// Takes it off the profile and leaves everything else alone.
    private func makePrivate(_ summary: PublicPlaylistSummary) async {
        guard busyIDs.insert(summary.id).inserted else { return }
        defer { busyIDs.remove(summary.id) }

        do {
            try await PlaylistSharingService.shared.unpublish(sharedPlaylistID: summary.id)
            remove(summary)
            deps.showToast("“\(summary.name)” is private again")
        } catch {
            actionError = "Couldn't make “\(summary.name)” private."
        }
    }

    /// Two deletions in one press, and the message has to cover both: the row on
    /// the profile, and — when this device is also the one holding the playlist —
    /// the library copy, which now takes its orphaned songs with it.
    private func deleteMessage(for summary: PublicPlaylistSummary) -> String {
        guard let local = localPlaylist(for: summary) else {
            return "This removes it from your profile for good, along with anyone's access to it. It isn't in this library, so there's nothing else to delete."
        }
        let songs = deps.libraryService.songCountRemovedWithPlaylist(id: local.id)
        return "This removes it from your profile and anyone's access to it. "
            + PlaylistDeletionPrompt.message(songCount: songs, isReadOnly: false)
    }

    /// Deletes the published row, and the local playlist too when there is one.
    ///
    /// Server first: if that fails there's nothing to undo, whereas deleting
    /// locally first and then failing would strand the row on the profile with
    /// the only thing that could remove it now gone.
    private func deletePlaylist(_ summary: PublicPlaylistSummary) async {
        pendingDelete = nil
        guard busyIDs.insert(summary.id).inserted else { return }
        defer { busyIDs.remove(summary.id) }

        let local = localPlaylist(for: summary)

        do {
            try await PlaylistSharingService.shared.deletePublished(sharedPlaylistID: summary.id)
        } catch {
            actionError = "Couldn't delete “\(summary.name)”."
            return
        }

        if let local {
            deps.libraryService.deletePlaylist(id: local.id)
            #if os(macOS)
            if appState.selectedPlaylist?.id == local.id { appState.selectedPlaylist = nil }
            #endif
        }

        remove(summary)
        deps.showToast("Deleted “\(summary.name)”")
    }

    /// Drops the card without a round trip. Re-fetching would work, but it would
    /// read a row we just deleted, and a card that lingers for the length of a
    /// request reads as the action having failed.
    private func remove(_ summary: PublicPlaylistSummary) {
        playlists.removeAll { $0.id == summary.id }
    }

    /// A top artist opens in Discover, not in the local library.
    ///
    /// Deliberately not routed through the "local artist first" rule the mini
    /// player uses: this is a stat off someone else's profile, and the interesting
    /// page is the artist as they exist online — which is also the only page that
    /// exists at all when you don't own a note of their music.
    private func openArtist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        appState.showOnlineArtist(name: trimmed, trackID: nil)
        #else
        iosAppState.pendingDiscoverArtistName = trimmed
        iosAppState.selectedTab = .discover
        #endif
    }

    private func pluralised(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: - Metrics

    private enum Metrics {
        #if os(macOS)
        static let avatar: CGFloat        = 168
        // Room for the floating back control that the Mac page overlays here.
        static let headerTop: CGFloat     = 52
        static let headerSpacing: CGFloat = 26
        static let pageInset: CGFloat     = 28
        static let cardMin: CGFloat       = 150
        static let cardMax: CGFloat       = 190
        static let nameFont: Font         = .system(size: 52, weight: .bold)
        #else
        static let avatar: CGFloat        = 104
        static let headerTop: CGFloat     = 16
        static let headerSpacing: CGFloat = 16
        static let pageInset: CGFloat     = 18
        static let cardMin: CGFloat       = 140
        static let cardMax: CGFloat       = 180
        static let nameFont: Font         = .system(size: 30, weight: .bold)
        #endif
    }
}

// MARK: - Artist circle

/// A top artist. The stat itself is a name and a play count — the photo is
/// resolved separately (ProfileArtwork.swift) and arrives a moment later, so the
/// monogram is what's drawn until it does and what stays if it never comes.
private struct ArtistCircle: View {

    let name: String
    let plays: Int
    let photo: ResolvedArtwork?
    let action: () -> Void

    @State private var isHovering = false

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ProfileArtworkView(artwork: photo) { monogram }
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(Color.mixSeparator, lineWidth: 0.5)
                    )
                    // Lifts on hover the way the Discover circles do — the whole
                    // point of the change is that this is now the same kind of
                    // thing as those, and it should read as one before it's clicked.
                    .scaleEffect(isHovering ? 1.04 : 1)
                    .mixAnimation(.easeOut(duration: 0.2), value: photo)
                    .mixAnimation(.easeOut(duration: 0.14), value: isHovering)

                VStack(spacing: 2) {
                    Text(name)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text("\(plays) play\(plays == 1 ? "" : "s")")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: 112)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovering = $0 }
        .help("Open \(name) in Discover")
    }

    private var monogram: some View {
        Color.mixSurface
            .overlay(
                Text(initials)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
            )
    }
}

// MARK: - Playlist card

private struct PublicPlaylistCard: View {

    let summary: PublicPlaylistSummary
    let cover: ResolvedArtwork?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The cover comes from the viewer's side — nothing published carries
            // one. See ProfileArtwork.swift.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ProfileArtworkView(artwork: cover) { coverPlaceholder }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
                )
                .mixAnimation(.easeOut(duration: 0.2), value: cover)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Color.mixSurface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .mixAnimation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var coverPlaceholder: some View {
        Color.mixSurface2
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.mixTextTertiary)
            )
    }

    /// The description if there is one, because the owner wrote it on purpose;
    /// the count only when there's nothing better to say.
    private var subtitle: String {
        if let d = summary.description, !d.isEmpty { return d }
        return "\(summary.trackCount) song\(summary.trackCount == 1 ? "" : "s")"
    }
}

// MARK: - Hint card

/// The quiet "nothing here" block, shared by the empty states on this page.
private struct HintCard: View {

    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextSecondary)
                Text(message)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        )
    }
}
