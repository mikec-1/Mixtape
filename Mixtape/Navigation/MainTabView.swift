import SwiftUI

public struct MainTabView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    @State private var selectedTab: AppTab = .home
    @State private var showSettings = false
    #if os(iOS)
    /// Lets anything request a Settings page. See SettingsRoute.
    @ObservedObject private var settingsRoute = SettingsRoute.shared
    @ObservedObject private var notifier = InviteNotifier.shared
    #endif

    #if os(iOS)
    // iOS import review queue; ImportView enqueues, this presents
    // IOSMetadataReviewSheet one item at a time.
    @StateObject private var iosAppState = IOSAppState()
    @Environment(\.scenePhase) private var scenePhase
    #endif

    /// On iOS routes through IOSAppState so the mini player / now-playing sheet
    /// can switch tabs.
    private var tabSelection: Binding<AppTab> {
        #if os(iOS)
        // Home and Discover share the `.home` tab; `.discover` is still requested by
        // name, so it maps onto the same tab.
        return Binding(
            get: {
                switch iosAppState.selectedTab {
                case .discover: return .home
                default:        return iosAppState.selectedTab
                }
            },
            set: { tab in
                switch tab {
                case .home:   iosAppState.goHome()
                case .search: iosAppState.goToSearch()
                default:      if iosAppState.selectedTab != tab { iosAppState.selectedTab = tab }
                }
            }
        )
        #else
        return $selectedTab
        #endif
    }

    public var body: some View {
        tabContent
        #if os(iOS)
        .environmentObject(iosAppState)
        .onReceive(NotificationCenter.default.publisher(for: .mixSpotlightArtist)) { _ in
            if let name = SpotlightIndex.takePendingArtist() { iosAppState.openOnlineArtist(name: name) }
        }
        .onAppear {
            if let name = SpotlightIndex.takePendingArtist() { iosAppState.openOnlineArtist(name: name) }
            openTappedNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixNotificationTap)) { _ in openTappedNotification() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { openTappedNotification() } }
        .onReceive(NotificationCenter.default.publisher(for: .mixFocusSearch)) { _ in iosAppState.focusSearch() }
        // View on a toast. The page opens on the tabs, so whatever covers them closes.
        .onReceive(NotificationCenter.default.publisher(for: .mixOpenPlaylist)) { note in
            guard let id = note.object as? UUID, let playlist = deps.libraryService.playlist(id: id) else { return }
            iosAppState.showNowPlaying = false
            iosAppState.showMessages = false
            iosAppState.infoTrack = nil
            showSettings = false
            iosAppState.openLibraryPlaylist(playlist)
        }
        .onChange(of: settingsRoute.request) { _, request in
            if request != nil { showSettings = true }
        }
        // Settings opens as a sheet from the Home gear button.
        .sheet(isPresented: $showSettings) {
            // SettingsView provides its own NavigationStack on iOS.
            SettingsView(authService: deps.authService,
                         syncService: deps.syncService,
                         libraryService: deps.libraryService,
                         importService: deps.importService,
                         statsService: deps.statsService,
                         profileStats: deps.profileStatsService,
                         downloadManager: deps.downloadManager)
        }
        // Presented here so it survives the mini player unmounting mid-skip.
        .fullScreenCover(isPresented: $iosAppState.showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(deps)
                .environmentObject(iosAppState)
                // Clear, so pulling the player down shows the app under it.
                .presentationBackground(.clear)
        }
        .fullScreenCover(isPresented: $iosAppState.showMessages) {
            MessagesView()
                .environmentObject(engine)
                .environmentObject(deps)
                .environmentObject(iosAppState)
        }
        // Hosted here since the menu that opened it is gone by then.
        // Not while the player is up; its queue sheet hosts its own.
        .sheet(item: Binding(get: { iosAppState.showNowPlaying ? nil : iosAppState.infoTrack },
                             set: { iosAppState.infoTrack = $0 })) { track in
            GetInfoSheet(track: track,
                         isOnline: deps.onlineCoordinator.hasActiveOnlineSession,
                         followsPlayback: false)
                .environmentObject(engine)
                .environmentObject(deps)
                .environmentObject(deps.queueService)
                .environmentObject(iosAppState)
        }
        // Not while the player is up; it presents its own.
        .sheet(item: Binding(get: { iosAppState.showNowPlaying ? nil : iosAppState.editTrack },
                             set: { iosAppState.editTrack = $0 })) { track in
            SongEditor(track: track, onOpenPost: { iosAppState.openPost(code: $0) })
                .environmentObject(deps)
        }
        .sheet(item: Binding(get: { iosAppState.showNowPlaying ? nil : iosAppState.postTrack },
                             set: { iosAppState.postTrack = $0 })) { track in
            PostSheet(track: track, onOpen: { iosAppState.openPost(code: $0) })
                .environmentObject(deps)
        }
        // Present metadata review sheet whenever the queue is non-empty.
        .sheet(item: Binding(
            get: { iosAppState.importSheetOpen ? nil : iosAppState.pendingReview },
            set: { _ in iosAppState.dequeueReview() }
        )) { item in
            IOSMetadataReviewSheet(item: item)
                .environmentObject(deps)
                .environmentObject(iosAppState)
        }
        #endif
    }

    // Extracted so the #if os(iOS) modifiers above can be applied cleanly.
    private var tabContent: some View {
        // Sync status lives in `LibraryView`. Tab bar gets a plain line underneath.
        ZStack(alignment: .bottom) {
            TabView(selection: tabSelection) {
                #if os(iOS)
                // Home + Discover landing. Carries Home's gear and avatar.
                IOSDiscoverView(
                    onOpenSettings: { showSettings = true }
                )
                .tag(AppTab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }
                #else
                NavigationStack {
                    HomeView(onQuickLink: handleQuickLink, onPlay: handlePlay, onArtist: handleArtist)
                }
                .tag(AppTab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }
                #endif

                SearchView()
                    .tag(AppTab.search)
                    .tabItem { Label("Search", systemImage: MixtapeIcons.search) }

                #if os(iOS)
                CommunityTab()
                    .tag(AppTab.community)
                    .tabItem { Label("Community", systemImage: "person.2.fill") }
                #endif

                LibraryView(libraryService: deps.libraryService)
                    .tag(AppTab.library)
                    .tabItem { Label("Library", systemImage: MixtapeIcons.library) }
                    #if os(iOS)
                    // The inbox and messages live in Library's header.
                    .badge(notifier.unread)
                    #endif
            }
            // System tab bar with just a tint, so it keeps the native blur and
            // Reduce Transparency fallback.
            .tint(Color.mixPrimary)

            KeyboardAware { typing in miniPlayerLayer(typing: typing) }
        }
    }

    // MARK: - Mini Player Layer

    /// Own container so its spring doesn't animate tab transitions. Ignores the
    /// keyboard safe area and hides while typing.
    private func miniPlayerLayer(typing: Bool) -> some View {
        let shows = showsMiniPlayer(typing: typing)
        return ZStack(alignment: .bottom) {
            if shows {
                MiniPlayerBar()
                    .padding(.bottom, MiniPlayerMetrics.overlayBottomPadding)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Above the pill, clear of the tab buttons.
            OfflineStrip(downloads: deps.downloadManager, auth: deps.authService)
                .padding(.bottom, MiniPlayerMetrics.overlayBottomPadding
                                  + (shows ? MiniPlayerMetrics.barHeight + 8 : 0))

            // Just above the song name whether or not the pill is up.
            TrackPreparingBar(coordinator: deps.onlineCoordinator)
                .padding(.bottom, MiniPlayerMetrics.overlayBottomPadding
                                  + (shows ? MiniPlayerMetrics.barHeight + 8 : 0))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .mixAnimation(.spring(response: 0.35, dampingFraction: 0.8), value: shows)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Something is loaded *and* nothing is being typed into.
    private func showsMiniPlayer(typing: Bool) -> Bool {
        engine.state.isActive && !typing
    }

    #if os(iOS)
    private func openTappedNotification() {
        // A tap arrives mid-foregrounding; presenting before the scene is active can leave a black screen.
        guard scenePhase == .active else { return }
        switch InviteNotifier.shared.takePendingTap() {
        case .messages(let person): iosAppState.openMessages(with: person)
        case .jam(let code):
            // The Jam sheet goes over the tabs, not stacked on a clear full-screen cover.
            iosAppState.showNowPlaying = false
            iosAppState.showMessages = false
            Task { await deps.jam.join(code: code) }
        case .album(let title, let artist): iosAppState.openOnlineAlbum(title: title, artistName: artist)
        case nil: break
        }
    }
    #endif

    // MARK: - Quick-link routing

    /// Quick links jump to the Library tab.
    private func handleQuickLink(_ link: HomeQuickLink) {
        tabSelection.wrappedValue = .library
    }

    /// Local artist page, or the online one for unmatched names.
    private func handleArtist(_ name: String) {
        #if os(iOS)
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    // MARK: - Home playback routing

    /// Online tracks go through OnlinePlaybackCoordinator, not the offline engine.
    private func handlePlay(_ track: Track, context: [Track], origin: String) {
        Task {
            if deps.onlineCoordinator.isStandaloneOnline(track) {
                await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
            } else {
                await engine.play(track: track, in: context, source: .named(origin))
            }
        }
    }

}

#if os(iOS)
/// Its own stack, so a post or profile opened here stays on this tab.
private struct CommunityTab: View {
    private enum Route: Hashable { case post(String), profile(UserProfile) }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            CommunityView(onOpenPost: { path.append(.post($0)) }, onOpenProfile: { path.append(.profile($0)) })
                .miniPlayerSafeArea()
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .post(let code):
                            PostPageView(code: code, onOpenProfile: { path.append(.profile($0)) })
                        case .profile(let profile):
                            ProfilePageView(profile: profile, onOpenPost: { path.append(.post($0)) },
                                            onOpenProfile: { path.append(.profile($0)) })
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    .miniPlayerSafeArea()
                }
        }
    }
}
#endif

// MARK: - Keyboard

/// Reads the keyboard in its own body so showing it only redraws the mini
/// player and toasts, not the whole TabView.
private struct KeyboardAware<Content: View>: View {
    #if os(iOS)
    @ObservedObject private var keyboard = KeyboardVisibility.shared
    #endif
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        #if os(iOS)
        content(keyboard.isVisible)
        #else
        content(false)
        #endif
    }
}

// MARK: - App Tab

public enum AppTab: Hashable {
    case home, library, search, community, discover, nowPlaying, settings
}

// MARK: - Preview

#Preview {
    MainTabView()
        .environmentObject(AppDependencies())
}
