// A user's profile as a page, yours or anyone's: hero with avatar, handle, follow counts and
// Follow, top artists, their posts, reposts and likes, then public playlists. Same page as
// mixtape-web src/pages/@[handle].astro. On your own profile it also says what others can see.

import SwiftUI

public struct ProfilePageView: View {

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    private let profile: UserProfile
    /// Where posts and other profiles open. Nil: a push on iOS, the content column on Mac.
    private let onOpenPost: ((String) -> Void)?
    private let onOpenProfile: ((UserProfile) -> Void)?

    @State private var stats: PublicProfileStats?
    @State private var playlists: [PublicPlaylistSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showingAllPlaylists = false
    /// iOS only; macOS routes through MacAppState so the playlist gets the content column.
    @State private var openPlaylist: PublicPlaylistSummary?

    /// Per summary, so the menu can act on any card without a selection.
    @State private var manageCollaborators: PublicPlaylistSummary?
    @State private var pendingDelete: PublicPlaylistSummary?
    @State private var editingPlaylist: Playlist?
    @State private var actionError: String?
    /// Cards with a request in flight, so a second Delete can't land.
    @State private var busyIDs: Set<UUID> = []
    /// Their live Jam's code, when they've messaged you.
    @State private var jamCode: String?
    /// Their shared recaps. Your own come from RecapService.
    @State private var recaps: [RecapService.Recap] = []
    @State private var follows: (followers: Int, following: Int, mine: Bool)?
    @State private var followBusy = false
    @State private var blocked: Bool?
    @State private var confirmingBlock = false
    @State private var postsTab: ProfilePostsTab = .posts
    #if os(iOS)
    @State private var pushedPost: String?
    @State private var pushedProfile: UserProfile?
    #endif

    /// See ProfileArtwork.swift for where these come from.
    @StateObject private var artwork = ProfileArtworkStore()

    public init(profile: UserProfile, onOpenPost: ((String) -> Void)? = nil,
                onOpenProfile: ((UserProfile) -> Void)? = nil) {
        self.profile = profile
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
    }

    private var viewer: UUID? { deps.authService.currentUser?.id }
    private var isMe: Bool { viewer == profile.id }

    /// Two rows at most window widths.
    private static let collapsedPlaylistCount = 6

    private var visiblePlaylists: [PublicPlaylistSummary] {
        showingAllPlaylists ? playlists : Array(playlists.prefix(Self.collapsedPlaylistCount))
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header

                if let jamCode {
                    JamBanner(name: profile.name, code: jamCode)
                        .frame(maxWidth: 560)
                }

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
                    postsSection
                    RecapShelf(recap: deps.recap, profile: profile, isMe: isMe, others: recaps)
                    playlistsSection
                    if loadFailed {
                        emptyState
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.pageInset)
            .padding(.bottom, 48)
        }
        // Applied out here so the wash spans the whole window, like other detail pages.
        .artworkWash(source: artwork.avatar, fallback: ArtworkColors.brandGradient)
        .background(MixPageBackground())
        .navigationTitle(profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        // Pushed, not presented: this page always lives in a NavigationStack on iOS.
        .navigationDestination(item: $openPlaylist) { summary in
            PublicPlaylistPage(summary: summary, ownerName: profile.name)
                .environmentObject(deps)
        }
        .navigationDestination(item: $pushedPost) { PushedPost(code: $0) }
        .navigationDestination(item: $pushedProfile) { ProfilePageView(profile: $0) }
        #endif
        .sheet(item: $manageCollaborators) { summary in
            InviteCollaboratorsSheet(sharedPlaylistID: summary.id,
                                     localPlaylistID: localPlaylist(for: summary)?.id,
                                     name: summary.name,
                                     coverData: coverData(for: summary),
                                     // Only reachable from `isMe`, and the rows were fetched by owner id.
                                     isOwner: true)
                .environmentObject(deps)
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorSheet(editingPlaylist: playlist)
                .environmentObject(deps)
        }
        .mixConfirmationDialog(
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
        .task(id: profile.id) {
            jamCode = isMe ? nil : await deps.jam.profileJamCode(of: profile.id)
        }
        // Keyed on who's looking too, so signing in shows whether you follow them.
        .task(id: [profile.id, viewer]) {
            follows = try? await deps.community.follows(of: profile.id)
            blocked = isMe || viewer == nil ? nil : await MessagesService.shared.isBlocked(profile.id)
        }
        .mixConfirmationDialog("Block \(profile.name)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await setBlocked(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won\u{2019}t see each other\u{2019}s posts or comments, follows between you end, and neither of you can message the other.")
        }
    }

    // MARK: - Header

    /// The hero band. Its colour comes from `artworkWash` on the body.
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

                if !isMe, deps.authService.currentUser != nil {
                    HStack(spacing: 8) {
                        followButton
                        messageButton
                        if blocked != nil { moreMenu }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.bottom, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.headerTop)
        .padding(.bottom, 8)
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.mixLabel)
            .foregroundStyle(filled ? Color.mixOnAccent : Color.mixTextPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(filled ? AnyShapeStyle(Color.mixAccentFill) : AnyShapeStyle(Color.mixSurface), in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Color.mixSeparator) } }
    }

    /// Optimistic; a failure puts it back and says so.
    private var followButton: some View {
        let on = follows?.mine == true
        return Button {
            Task { await setFollowing(!on) }
        } label: { pill(on ? "Following" : "Follow", filled: !on) }
            .buttonStyle(.plain)
            .mixHandCursor()
            .disabled(follows == nil || followBusy)
    }

    /// Opens Messages on this conversation: a page on Mac, the full-screen cover on iOS.
    private var messageButton: some View {
        Button {
            #if os(macOS)
            appState.openMessages(with: profile)
            #else
            iosAppState.openMessages(with: profile)
            #endif
        } label: { pill("Message", filled: false) }
            .buttonStyle(.plain)
            .mixHandCursor()
    }

    private var moreMenu: some View {
        Menu {
            if blocked == true {
                Button("Unblock \(profile.name)") { Task { await setBlocked(false) } }
            } else {
                Button("Block \(profile.name)\u{2026}", role: .destructive) { confirmingBlock = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: 34, height: 34)
                .background(Color.mixSurface, in: Circle())
                .overlay { Circle().strokeBorder(Color.mixSeparator) }
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .accessibilityLabel("More")
    }

    private func setBlocked(_ on: Bool) async {
        do {
            try await MessagesService.shared.setBlocked(profile.id, on)
            blocked = on
            follows = try? await deps.community.follows(of: profile.id)
            deps.showToast(.done(on ? "Blocked \(profile.name)." : "Unblocked \(profile.name)."))
        } catch {
            actionError = "Couldn\u{2019}t \(on ? "block" : "unblock") @\(profile.username)."
        }
    }

    private func setFollowing(_ on: Bool) async {
        guard var f = follows else { return }
        let before = f
        f.mine = on
        f.followers += on ? 1 : -1
        follows = f
        followBusy = true
        defer { followBusy = false }
        do {
            try await deps.community.setFollowing(profile.id, on)
        } catch {
            follows = before
            actionError = "Couldn\u{2019}t \(on ? "follow" : "unfollow") @\(profile.username)."
        }
    }

    /// Only counts that exist. Plays drop out when stats sharing is off.
    private var statLine: some View {
        let parts: [String] = {
            var out = ["@\(profile.username)"]
            if let follows {
                out += [pluralised(follows.followers, "Follower"), "\(follows.following.formatted()) Following"]
            }
            out.append(pluralised(playlists.count, "Public Playlist"))
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

                // Says whether others can see this.
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

    // MARK: - Posts

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(ProfilePostsTab.allCases) { tab in
                    SectionChip(title: tab.title, isSelected: postsTab == tab) { postsTab = tab }
                }
            }
            PostList(key: "\(profile.id)\(postsTab)\(viewer?.uuidString ?? "")",
                     empty: postsEmpty,
                     load: { [id = profile.id, tab = postsTab, community = deps.community] in
                         try await community.profile(id, tab, after: $0)
                     },
                     onOpenPost: openPost, onOpenProfile: openProfile)
        }
    }

    private var postsEmpty: (title: String, message: String) {
        let who = isMe ? "You haven\u{2019}t" : "@\(profile.username) hasn\u{2019}t"
        switch postsTab {
        case .posts:   return ("No posts yet", isMe ? "Post an edit from your library and it shows up here." : "\(who) posted an edit yet.")
        case .reposts: return ("No reposts yet", "\(who) reposted anything yet.")
        case .likes:   return ("No likes yet", "\(who) liked any posts yet.")
        }
    }

    private func openPost(_ code: String) {
        if let onOpenPost { return onOpenPost(code) }
        #if os(macOS)
        appState.showPost(code: code, from: profile)
        #else
        pushedPost = code
        #endif
    }

    private func openProfile(_ other: UserProfile) {
        guard other.id != profile.id else { return }
        if let onOpenProfile { return onOpenProfile(other) }
        #if os(macOS)
        appState.showProfile(other)
        #else
        pushedProfile = other
        #endif
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

                        // Owner actions only. An empty `.contextMenu` still eats the long-press on iOS.
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

    /// Same actions as the playlist page's "...", addressing the shared row by id so a
    /// published row with no local copy can still be deleted.
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

        // Codes and links only come from the invite screen.
        Button { manageCollaborators = summary } label: {
            Label("Manage Collaborators", systemImage: "person.2")
        }

        // Editing needs the local playlist; the published row is only a snapshot.
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

    // MARK: - Error

    private var emptyState: some View {
        HintCard(icon: "wifi.exclamationmark",
                 title: "Couldn't load this profile",
                 message: "Check your connection and try again.")
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadFailed = false

        // Not awaited with the fetches below, so the wash doesn't wait for stats.
        Task { await artwork.resolveAvatar(profile.avatarURL) }

        async let s = deps.profileStatsService.fetchStats(for: profile.id)
        async let p = deps.profileStatsService.fetchPublicPlaylists(for: profile.id)
        async let r = isMe ? nil : deps.recap.fetchRecaps(userID: profile.id)

        // Stats and playlists fail independently. Only a total miss is an error.
        let loadedStats     = try? await s
        let loadedPlaylists = try? await p

        stats     = loadedStats ?? nil
        playlists = loadedPlaylists ?? []
        recaps    = await r ?? []
        loadFailed = loadedStats == nil && loadedPlaylists == nil
        isLoading  = false

        // After the spinner drops: pictures come from the library and catalogue, not these requests.
        await resolveArtwork()

        // Only the owner's device holds the image, so repair missing published covers here.
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

    /// A full page on both platforms: the content column on macOS, a push on iOS.
    private func open(_ summary: PublicPlaylistSummary) {
        #if os(macOS)
        appState.showPublicPlaylist(summary, ownerName: profile.name)
        #else
        openPlaylist = summary
        #endif
    }

    // MARK: - Playlist actions

    /// The local playlist behind a published row, if this device has one. The owner's row
    /// carries its `playlistID`; a share is linked the other way, so check both.
    private func localPlaylist(for summary: PublicPlaylistSummary) -> Playlist? {
        if let mine = deps.libraryService.playlist(id: summary.playlistID) { return mine }
        if let localID = PlaylistSharingService.shared.localPlaylistID(forSharedPlaylist: summary.id) {
            return deps.libraryService.playlist(id: localID)
        }
        return nil
    }

    /// The cover the grid already drew, if it came from local data.
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
            deps.showToast(.done("“\(summary.name)” is private again"))
        } catch {
            actionError = "Couldn't make “\(summary.name)” private."
        }
    }

    /// Covers both deletions: the profile row and, if present, the library copy.
    private func deleteMessage(for summary: PublicPlaylistSummary) -> String {
        guard let local = localPlaylist(for: summary) else {
            return "This removes it from your profile for good, along with anyone's access to it. It isn't in this library, so there's nothing else to delete."
        }
        let songs = deps.libraryService.songCountRemovedWithPlaylist(id: local.id)
        return "This removes it from your profile and anyone's access to it. "
            + PlaylistDeletionPrompt.message(songCount: songs, isReadOnly: false)
    }

    /// Deletes the published row, then the local playlist. Server first, so a failure
    /// doesn't strand the row with nothing left to remove it.
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
            SupabaseSyncService.allowBulk("delete-playlists")
            deps.libraryService.deletePlaylist(id: local.id)
            #if os(macOS)
            if appState.selectedPlaylist?.id == local.id { appState.selectedPlaylist = nil }
            #endif
        }

        remove(summary)
        deps.showToast(.done("Deleted “\(summary.name)”"))
    }

    /// Drops the card locally; a refetch could still read the deleted row.
    private func remove(_ summary: PublicPlaylistSummary) {
        playlists.removeAll { $0.id == summary.id }
    }

    /// Opens the artist in Discover, not the local library.
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
        // Computed so it follows text size changes; a `static let` would freeze it.
        static var nameFont: Font         { .system(size: MixFontScale.size(30), weight: .bold) }
        #endif
    }
}

// MARK: - Artist circle

/// A top artist. The photo arrives later (ProfileArtwork.swift); the monogram stays if it never does.
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
                    // Hover lift, like the Discover circles.
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
                    .font(.system(size: MixFontScale.size(30), weight: .semibold))
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
            // Resolved on the viewer's side. See ProfileArtwork.swift.
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

    /// The owner's description, else the song count.
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

#if os(iOS)
/// A post pushed from a profile with no route of its own. Its authors push from here.
private struct PushedPost: View {
    let code: String
    @State private var profile: UserProfile?

    var body: some View {
        PostPageView(code: code, onOpenProfile: { profile = $0 })
            .navigationDestination(item: $profile) { ProfilePageView(profile: $0) }
    }
}
#endif
