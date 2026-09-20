// MainTabView.swift
// Mixtape — Navigation

import SwiftUI

public struct MainTabView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    @State private var selectedTab: AppTab = .home
    @State private var showSettings = false
    #if os(iOS)
    /// Lets anything in the app ask for a Settings page — the Spotify library
    /// import is reached that way now. See SettingsRoute.
    @ObservedObject private var settingsRoute = SettingsRoute.shared
    #endif

    #if os(iOS)
    // Review queue for enrichment candidates found during iOS import.
    // Passed down as an environment object so ImportView can enqueue items,
    // and consumed here to present IOSMetadataReviewSheet one item at a time.
    @StateObject private var iosAppState = IOSAppState()
    #endif

    /// Tab selection binding — on iOS it routes through IOSAppState so navigation
    /// requests from the mini player / now-playing sheet can switch tabs;
    /// elsewhere it falls back to local @State.
    private var tabSelection: Binding<AppTab> {
        #if os(iOS)
        // Home and Discover are one tab now, tagged `.home`. `.discover` is
        // still a live request — the mini player and the now-playing sheet both
        // ask for it by name to open an online artist — so it's folded onto the
        // same tab here rather than removed, which would have left those
        // requests selecting a tag no tab carries and silently doing nothing.
        //
        // `.search` is a page again. It used to fold onto the landing's search
        // field, on the reasoning that a second search could only see the local
        // library — but SearchView reaches the catalogue as well, and the tab
        // that people actually press should open the thing it names.
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
                default:      iosAppState.selectedTab = tab
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
        // The full player. Presented here rather than by the mini player so it
        // survives the bar unmounting mid-skip — see `IOSAppState.showNowPlaying`.
        .fullScreenCover(isPresented: $iosAppState.showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(deps)
                .environmentObject(iosAppState)
                // Clear, so pulling the player down shows the app under it.
                .presentationBackground(.clear)
        }
        // Present metadata review sheet whenever the queue is non-empty.
        .sheet(item: Binding(
            get: { iosAppState.pendingReview },
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
        // "Syncing" used to be announced here, above every tab. It is a
        // statement about the library, and reading it while browsing the
        // catalogue or looking at a search result is noise — it now lives in
        // `LibraryView`, which is the screen it is describing.
        // Spotify's placement: a plain line under the tab bar, not a card.
        ZStack(alignment: .bottom) {
            TabView(selection: tabSelection) {
                #if os(iOS)
                // The merged front door. Home used to be its own tab beside
                // Discover, and neither was complete on its own — Home knew your
                // library but nothing about the catalogue, Discover the reverse.
                // Home is the second sub-tab of this landing now, so the two are
                // one destination and the tab bar is down to three.
                //
                // The gear and the avatar come with it: they were in Home's nav
                // bar (Apple's convention — Settings is not a tab), and this is
                // Home's nav bar now.
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

                LibraryView(libraryService: deps.libraryService)
                    .tag(AppTab.library)
                    .tabItem { Label("Library", systemImage: MixtapeIcons.library) }
            }
            // The bar is left to the system. `.tint` colours the selected
            // item; everything else — the translucent material, the way it
            // goes opaque when content scrolls under it, the automatic
            // fallback under Reduce Transparency — is behaviour UIKit already
            // has and that the old `UITabBarAppearance` override was throwing
            // away in exchange for a flat `mixSurface` fill. A tab bar that
            // does not blur is the single loudest tell that an app is not
            // native, and it was the first thing anyone saw here.
            .tint(Color.mixPrimary)

            KeyboardAware { typing in miniPlayerLayer(typing: typing) }
        }
        // In the home-indicator zone, over the bar's own backing: stacking it
        // under the TabView shrank the tabs and pushed the mini player onto them.
        .overlay(alignment: .bottom) {
            OfflineStrip(downloads: deps.downloadManager, auth: deps.authService)
                .ignoresSafeArea(edges: .bottom)
        }
        // Playback error toast — slides down from top, auto-dismisses after 5 s.
        // Still an overlay: it is transient and must not re-lay-out the page.
        .overlay(alignment: .top) {
            if let msg = engine.errorMessage {
                PlaybackErrorToast(message: msg)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .mixAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.errorMessage)
        // The bottom-corner messages, in one stack so they can never land on
        // top of each other: the "Added to \u{2026}" pill rides above the wide bar
        // toast, and both clear the mini player together.
        .overlay(alignment: .bottom) { KeyboardAware { typing in
            VStack(spacing: 0) {
                SavedToastHost(center: deps.savedToasts, bottomGap: 8)
                if let msg = deps.toastMessage {
                    PlaylistAddedToast(message: msg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            // Stack above the mini player when it's visible, otherwise just above the tab bar
            .padding(.bottom, showsMiniPlayer(typing: typing)
                ? MiniPlayerMetrics.overlayBottomPadding + MiniPlayerMetrics.barHeight + 10
                : MiniPlayerMetrics.tabBarHeight + 12)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .mixAnimation(.spring(response: 0.3, dampingFraction: 0.88), value: deps.toastMessage)
        } }
    }

    // MARK: - Mini Player Layer

    /// The pill, in its own bottom-anchored container so the show/hide spring
    /// belongs to it alone — an `.animation` on the outer ZStack would animate
    /// every tab transition underneath it too.
    ///
    /// It sits out the keyboard entirely: ignoring the keyboard safe area keeps
    /// SwiftUI from lifting it above the keys, and `showsMiniPlayer` takes it off screen
    /// while typing, so the keyboard is the top layer the way it should be.
    private func miniPlayerLayer(typing: Bool) -> some View {
        let shows = showsMiniPlayer(typing: typing)
        return ZStack(alignment: .bottom) {
            if shows {
                MiniPlayerBar()
                    .padding(.bottom, MiniPlayerMetrics.overlayBottomPadding)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Sits on top of the pill's own bottom padding, so it rides just
            // above the song name whether or not the pill is up — a cold song
            // is loading before there is anything to show in the pill.
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

    // MARK: - Quick-link routing

    /// Home quick-links jump to the Library tab (which hosts Songs/Albums/
    /// Artists/Playlists on iOS).
    private func handleQuickLink(_ link: HomeQuickLink) {
        tabSelection.wrappedValue = .library
    }

    /// Home artist taps route to the matching profile (local Library artist or,
    /// for an unmatched/featured name, the online Discover artist page).
    private func handleArtist(_ name: String) {
        #if os(iOS)
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    // MARK: - Home playback routing

    /// Home cards play through here so online (Discover) tracks are routed to
    /// the OnlinePlaybackCoordinator rather than the offline engine, which would
    /// otherwise report the song "hasn't been uploaded yet".
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

// MARK: - Keyboard

/// Reads the keyboard in its own body, so showing it redraws only the mini
/// player and toasts — not the whole TabView, which re-ran every tab's body
/// (Home's recommendation scan, an open playlist) on each search-bar tap.
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

// MARK: - Toasts

/// The chrome behind both transient messages.
///
/// They used to be two structs that had drifted: different corner strokes,
/// different shadow weights, different label sizes, one of them outlined in a
/// tinted red that fought the icon already saying the same thing. A floating
/// message is one component with two things to say, so it is drawn once.
///
/// Material rather than a flat fill, and no stroke: something laid over the
/// page reads as being *above* it because it blurs what it covers, which is
/// how every banner the system puts on screen behaves. The outline was the
/// substitute for that depth, and it stopped being needed the moment the
/// blur arrived. Under Reduce Transparency `MixChrome.material` hands back an
/// opaque surface on its own.
private struct MixToast: View {

    let icon: String
    let tint: Color
    let message: String
    var lineLimit: Int

    @Environment(\.mixChrome) private var chrome

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(chrome.material(.regularMaterial, flat: .mixSurface2),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .mixShadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .accessibilityElement(children: .combine)
    }
}

private struct PlaybackErrorToast: View {
    let message: String

    var body: some View {
        MixToast(icon: "exclamationmark.circle.fill",
                 tint: .mixDestructive,
                 message: message,
                 lineLimit: 3)
    }
}

private struct PlaylistAddedToast: View {
    let message: String

    var body: some View {
        MixToast(icon: "checkmark.circle.fill",
                 tint: .mixPrimary,
                 message: message,
                 lineLimit: 2)
    }
}

// MARK: - App Tab

public enum AppTab: Hashable {
    case home, library, search, discover, nowPlaying, settings
}

// MARK: - Preview

#Preview {
    MainTabView()
        .environmentObject(AppDependencies())
}
