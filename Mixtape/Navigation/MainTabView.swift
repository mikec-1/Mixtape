// MainTabView.swift
// Mixtape — Navigation

import SwiftUI

public struct MainTabView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    @State private var selectedTab: AppTab = .home
    @State private var showSettings = false

    #if os(iOS)
    // Review queue for enrichment candidates found during iOS import.
    // Passed down as an environment object so ImportView can enqueue items,
    // and consumed here to present IOSMetadataReviewSheet one item at a time.
    @StateObject private var iosAppState = IOSAppState()
    #endif

    public var body: some View {
        tabContent
        #if os(iOS)
        .environmentObject(iosAppState)
        // Settings opens as a sheet from the Home gear button.
        .sheet(isPresented: $showSettings) {
            // SettingsView provides its own NavigationStack on iOS.
            SettingsView(authService: deps.authService,
                         syncService: deps.syncService,
                         libraryService: deps.libraryService,
                         importService: deps.importService)
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
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView(onQuickLink: handleQuickLink, onPlay: handlePlay)
                    #if os(iOS)
                        // Settings lives behind a gear in the nav bar (Apple
                        // convention) rather than a tab, keeping the tab bar to
                        // four top-level destinations.
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { showSettings = true } label: {
                                    Image(systemName: MixtapeIcons.settings)
                                }
                                .tint(Color.mixPrimary)
                                .accessibilityLabel("Settings")
                            }
                        }
                    #endif
                }
                .tag(AppTab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }

                SearchView()
                    .tag(AppTab.search)
                    .tabItem { Label("Search", systemImage: MixtapeIcons.search) }

                LibraryView(libraryService: deps.libraryService)
                    .tag(AppTab.library)
                    .tabItem { Label("Library", systemImage: MixtapeIcons.library) }

                #if os(iOS)
                IOSDiscoverView()
                    .tag(AppTab.discover)
                    .tabItem { Label("Discover", systemImage: "sparkles") }
                #endif
            }
            .tint(Color.mixPrimary)
            .onAppear { configureTabBarAppearance() }

            // Mini player — visible whenever something is loaded
            if engine.state.isActive {
                MiniPlayerBar()
                    .padding(.bottom, tabBarHeight + 8)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.state.isActive)
            }
        }
        // Playback error toast — slides down from top, auto-dismisses after 5 s
        .overlay(alignment: .top) {
            if let msg = engine.errorMessage {
                PlaybackErrorToast(message: msg)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.errorMessage)
        // "Added to playlist" confirmation toast — slides up from bottom
        .overlay(alignment: .bottom) {
            if let msg = deps.toastMessage {
                PlaylistAddedToast(message: msg)
                    .padding(.horizontal, 16)
                    // Stack above the mini player when it's visible, otherwise just above the tab bar
                    .padding(.bottom, engine.state.isActive
                        ? tabBarHeight + 8 + 64 + 10   // 64 pt ≈ mini player height
                        : tabBarHeight + 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: deps.toastMessage)
    }

    // MARK: - Quick-link routing

    /// Home quick-links jump to the Library tab (which hosts Songs/Albums/
    /// Artists/Playlists on iOS).
    private func handleQuickLink(_ link: HomeQuickLink) {
        selectedTab = .library
    }

    // MARK: - Home playback routing

    /// Home cards play through here so online (Discover) tracks are routed to
    /// the OnlinePlaybackCoordinator rather than the offline engine, which would
    /// otherwise report the song "hasn't been uploaded yet".
    private func handlePlay(_ track: Track, context: [Track]) {
        Task {
            if deps.onlineCoordinator.isStandaloneOnline(track) {
                await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
            } else {
                await engine.play(track: track, in: context)
            }
        }
    }

    // MARK: - Tab Bar Appearance (iOS only)

    private var tabBarHeight: CGFloat { 49 }

    private func configureTabBarAppearance() {
        #if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.mixSurface)

        appearance.stackedLayoutAppearance.normal.iconColor         = UIColor(Color.mixTextTertiary)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.mixTextTertiary)]
        appearance.stackedLayoutAppearance.selected.iconColor        = UIColor(Color.mixPrimary)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(Color.mixPrimary)]

        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }
}

// MARK: - Playback Error Toast

private struct PlaybackErrorToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mixDestructive)
            Text(message)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mixDestructive.opacity(0.30), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

// MARK: - Playlist Added Toast

private struct PlaylistAddedToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mixSeparator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
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
