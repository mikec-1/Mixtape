// SettingsPanes.swift
// Mixtape — Features/Settings
//
// One view per settings category. Each pane owns the sheets and confirmations
// its own rows raise, so nothing has to be threaded back up to the shell — the
// shell only decides which pane is on screen.

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Account

struct AccountPane: View {

    @ObservedObject var vm: SettingsViewModel

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif
    @AppStorage(ProfileStatsService.sharingDefaultsKey) private var shareListeningActivity = true
    @State private var showFindPeople = false
    #if os(iOS)
    @State private var showAccount = false
    @State private var showMyProfile = false
    #endif

    /// The real `profiles` row for the signed-in user, once it arrives. The handle
    /// on that row is what other people see, and it can differ from the display
    /// name held locally — so the page opens on the local guess and corrects
    /// itself rather than making you wait for a round trip to press a button.
    @State private var resolvedProfile: UserProfile?

    /// The signed-in user seen as a `profiles` row — the shape the profile page
    /// takes for everyone.
    private var myProfile: UserProfile? {
        guard let user = vm.currentUser else { return nil }
        if let resolved = resolvedProfile, resolved.id == user.id { return resolved }
        return UserProfile(id: user.id,
                           username: user.username ?? user.displayName,
                           displayName: user.displayName,
                           avatarURL: user.avatarURL)
    }

    var body: some View {
        SettingsPage(title: "Account") {
            if let user = vm.currentUser {
                SettingsCard {
                    HStack(spacing: 14) {
                        AvatarView(url: user.avatarURL, fallbackText: user.displayName, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.displayName)
                                .font(.mixTitle2)
                                .foregroundStyle(Color.mixTextPrimary)
                                .lineLimit(1)
                            Text(user.email)
                                .font(.mixSubtext)
                                .foregroundStyle(Color.mixTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsMetrics.rowPadH)
                    .padding(.vertical, 14)
                }
            }

            SettingsGroup {
                // The only reliable way to know what you're publishing is to look
                // at the same page everyone else gets.
                if myProfile != nil {
                    SettingsButtonRow(id: "account.myProfile",
                                      title: "My Profile",
                                      subtitle: "See your profile the way other people do.",
                                      icon: "person.crop.square",
                                      role: .plain,
                                      showsChevron: true) {
                        guard let me = myProfile else { return }
                        #if os(macOS)
                        appState.showProfile(me)
                        #else
                        showMyProfile = true
                        #endif
                    }
                }

                SettingsButtonRow(id: "account.manage",
                                  title: "Manage Account",
                                  icon: "person.text.rectangle",
                                  role: .plain,
                                  showsChevron: true) {
                    #if os(macOS)
                    appState.showingAccount = true
                    #else
                    showAccount = true
                    #endif
                }

                SettingsButtonRow(id: "account.findPeople",
                                  title: "Find People",
                                  icon: "person.2",
                                  role: .plain,
                                  showsChevron: true) {
                    showFindPeople = true
                }
            }

            SettingsGroup(title: "Privacy") {
                SettingsToggleRow(id: "account.activity",
                                  title: "Show My Listening Activity",
                                  subtitle: "Lets people you follow see what you're playing.",
                                  icon: "waveform",
                                  isOn: $shareListeningActivity)
                    .onChange(of: shareListeningActivity) { _, newValue in
                        if let id = deps.authService.currentUser?.id {
                            Task { await deps.profileStatsService.setSharing(newValue, userID: id) }
                        }
                    }
            }

            // Account housekeeping the website owns, Spotify-style: one place,
            // reached from here and from the avatar menu.
            SettingsGroup(title: "On the Web") {
                SettingsLinkRow(id: "account.web", title: "Account Overview",
                                subtitle: "Devices, sign-in methods and privacy on mixtaped.tech.",
                                icon: "globe", url: MixtapeLink.web("account"))
                SettingsLinkRow(id: "account.export", title: "Download Your Data",
                                icon: "square.and.arrow.down",
                                url: MixtapeLink.web("account", focus: "account.export"))
                SettingsLinkRow(id: "account.privacy", title: "Privacy Policy",
                                icon: "hand.raised", url: MixtapeLink.web("privacy"))
            }

            SettingsGroup {
                SettingsButtonRow(id: "account.signOut",
                                  title: "Sign Out",
                                  icon: MixtapeIcons.signOut,
                                  role: .destructive) {
                    vm.showSignOutConfirm = true
                }
            }
        }
        .task(id: vm.currentUser?.id) {
            guard let id = vm.currentUser?.id else { resolvedProfile = nil; return }
            resolvedProfile = try? await deps.authService.fetchProfile(id: id)
        }
        .sheet(isPresented: $showFindPeople) {
            #if os(macOS)
            // The profile is a page in the main window, not something to view
            // through a 420pt porthole — so the sheet hands the choice back and
            // closes rather than pushing inside itself.
            FindPeopleView(authService: deps.authService) { profile in
                appState.showProfile(profile)
            }
            #else
            FindPeopleView(authService: deps.authService)
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showMyProfile) {
            NavigationStack {
                if let me = myProfile {
                    ProfilePageView(profile: me)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showMyProfile = false }
                                    .foregroundStyle(Color.mixPrimary)
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showAccount) {
            NavigationStack {
                AccountSettingsView()
                    .background(Color.mixBackground.ignoresSafeArea())
                    .navigationTitle("Account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAccount = false }
                                .foregroundStyle(Color.mixPrimary)
                        }
                    }
            }
        }
        #endif
        .confirmationDialog("Sign Out", isPresented: $vm.showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await vm.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to access your synced library.")
        }
    }
}

// MARK: - General

struct GeneralPane: View {

    @EnvironmentObject private var deps:  AppDependencies
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var meta = PlaylistMetadataService.shared
    #if os(iOS)
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    #endif
    #if os(macOS)
    @StateObject private var launchAtLogin = LaunchAtLogin.shared
    #endif
    var body: some View {
        SettingsPage(title: "General") {
            SettingsGroup(title: "Appearance") {
                SettingsPickerRow(id: "general.appearance",
                                  title: "Theme",
                                  icon: "circle.lefthalf.filled",
                                  selection: $theme.appearance,
                                  options: AppAppearance.allCases) { $0.title }
                    // The macOS pop-up caches its styling across an appearance
                    // flip and renders with the old look until touched.
                    // Rebuilding it on each change is the fix.
                    .id(theme.appearance)
            }

            SettingsGroup(title: "Interface", footer: theme.preset.detail) {
                // The preset first, and the three axes under it. Almost nobody
                // wants to reason about density, motion and effects separately
                // — they want the app smaller, or calmer, or both — but the
                // people who do want one without the others were the reason
                // this isn't a single three-way switch.
                SettingsPickerRow(id: "general.preset",
                                  title: "Look",
                                  icon: "sparkles",
                                  selection: Binding(get: { theme.preset },
                                                     set: { theme.preset = $0 }),
                                  options: presetOptions) { $0.title }

                SettingsPickerRow(id: "general.density",
                                  title: "Layout Density",
                                  subtitle: "Compact draws smaller rows, covers and headers.",
                                  icon: "rectangle.compress.vertical",
                                  selection: $theme.density,
                                  options: MixDensity.allCases) { $0.title }

                SettingsPickerRow(id: "general.motion",
                                  title: "Animation",
                                  subtitle: "Reduced switches off the app's own animation. System transitions are left alone.",
                                  icon: "wand.and.rays",
                                  selection: $theme.motion,
                                  options: MixMotion.allCases) { $0.title }

                SettingsPickerRow(id: "general.chrome",
                                  title: "Visual Effects",
                                  subtitle: "Flat drops the artwork colour wash, cover shadows and blur.",
                                  icon: "square.stack.3d.up",
                                  selection: $theme.chrome,
                                  options: MixChrome.allCases) { $0.title }
            }

            SettingsGroup(title: "Library",
                          footer: "All Songs lists everything you've imported, liked or not. "
                                + "Off, Liked Songs is the only list of your whole library.") {
                SettingsToggleRow(id: "general.allSongs",
                                  title: "Show All Songs",
                                  icon: MixtapeIcons.playlist,
                                  isOn: $meta.showsAllSongs)
            }

            #if os(iOS)
            SettingsGroup(title: "Interaction") {
                SettingsToggleRow(id: "general.haptics",
                                  title: "Haptic Feedback",
                                  icon: "hand.tap",
                                  isOn: $hapticsEnabled)
            }
            #endif

            #if os(macOS)
            SettingsGroup(title: "Startup",
                          footer: launchAtLogin.failure.map {
                              "macOS refused the login item: \($0)"
                          }) {
                SettingsToggleRow(id: "general.launchAtLogin",
                                  title: "Open Mixtape at Login",
                                  icon: "power",
                                  isOn: launchAtLogin.binding)
            }
            #endif
        }
        #if os(macOS)
        .onAppear { launchAtLogin.refresh() }
        #endif
    }

    /// Custom is arrived at, not chosen — so it's only in the list when that's
    /// where the three axes already are. A Picker whose selection isn't among
    /// its options draws blank, which is the one thing this has to avoid.
    private var presetOptions: [MixAppearancePreset] {
        theme.preset == .custom ? MixAppearancePreset.allCases
                                : MixAppearancePreset.selectable
    }
}

// MARK: - Playback

struct PlaybackPane: View {

    // Handed in rather than reached for through AppDependencies: only these two
    // republish, and a picker bound to an object nobody observes shows a stale
    // value after every change.
    @ObservedObject var engine:    PlaybackEngine
    @ObservedObject var equalizer: AudioEqualizer

    #if os(iOS)
    @State private var showEqualizer = false
    #endif

    /// Same key as `ResolverPreferences.preferCensored`, read here through
    /// `@AppStorage` so the row redraws when it changes. The resolvers read the
    /// default directly — they run off the main actor and have no view to bind.
    @AppStorage("mixtape.resolver.preferCensored") private var preferCensored = false

    /// The speeds offered in Settings. The player's own speed menu can land
    /// between these, so the row snaps to the nearest rather than showing blank.
    private static let speeds: [PlaybackSpeed] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        .map(PlaybackSpeed.init)

    private var speedBinding: Binding<PlaybackSpeed> {
        Binding(
            get: {
                let current = Double(engine.playbackRate)
                return Self.speeds.min { abs($0.value - current) < abs($1.value - current) }
                    ?? PlaybackSpeed(value: 1.0)
            },
            set: { engine.setRate(Float($0.value)) }
        )
    }

    var body: some View {
        SettingsPage(title: "Playback") {
            SettingsGroup(title: "Transitions") {
                SettingsPickerRow(id: "playback.crossfade",
                                  title: "Crossfade",
                                  icon: "wand.and.rays",
                                  selection: Binding(
                                    get: { engine.crossfadeMode },
                                    set: { engine.setCrossfadeMode($0) }
                                  ),
                                  options: CrossfadeMode.allCases) { $0.title }

                if engine.crossfadeMode == .crossfade {
                    SettingsSliderRow(id: "playback.crossfadeLength",
                                      title: "Crossfade Length",
                                      icon: "timer",
                                      value: Binding(
                                        get: { engine.crossfadeDuration },
                                        set: { engine.setCrossfadeDuration($0) }
                                      ),
                                      range: 2...12,
                                      step: 1) { "\(Int($0))s" }
                }
            }

            SettingsGroup(title: "Speed") {
                SettingsPickerRow(id: "playback.speed",
                                  title: "Playback Speed",
                                  icon: "speedometer",
                                  selection: speedBinding,
                                  options: Self.speeds) { $0.title }
            }

            SettingsGroup(title: "Versions",
                          footer: "Applies to songs fetched from now on. A song already in the playback cache keeps the version it was fetched as until you use \u{201C}Wrong version\u{201D} on it.") {
                SettingsToggleRow(id: "playback.preferCensored",
                                  title: "Prefer Censored Versions",
                                  subtitle: "Look for the clean edit first, and fall back to the explicit one when there isn't a clean release.",
                                  icon: "ear.badge.checkmark",
                                  isOn: $preferCensored)
            }

            #if os(macOS)
            // Inline on macOS — the ten-band EQ fits the wider layout, and
            // hiding it behind a sheet on a desktop would be odd. It carries its
            // own header and padding, so it gets the card's border rather than
            // being wrapped in a SettingsGroup that would title it twice.
            EqualizerView(equalizer: equalizer)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                        .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
                )
            #else
            SettingsGroup(title: "Equalizer") {
                SettingsButtonRow(id: "playback.equalizer",
                                  title: "Equalizer",
                                  icon: "slider.vertical.3",
                                  role: .plain,
                                  showsChevron: true) {
                    showEqualizer = true
                } trailing: {
                    SettingsValue(text: equalizer.isEnabled
                                  ? equalizer.preset.rawValue
                                  : "Off")
                }
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showEqualizer) {
            MixSheet(title: "Equalizer",
                     subtitle: "10-band graphic EQ. Changes are heard as you make them.",
                     size: .large) {
                EqualizerView(equalizer: equalizer, isEmbedded: true)
            }
        }
        #endif
    }
}

/// A speed the picker can bind to. `Float` isn't `Identifiable`, and rounding
/// the raw rate into a label at display time loses the selection.
struct PlaybackSpeed: Identifiable, Hashable {
    let value: Double
    var id: Double { value }
    var title: String { value == 1.0 ? "Normal" : String(format: "%g×", value) }
}

// MARK: - Downloads

struct DownloadsPane: View {

    @ObservedObject var manager: DownloadManager
    @EnvironmentObject private var exportManager: ExportManager
    @ObservedObject private var prefetch = PlaybackPrefetchSettings.shared
    @State private var confirmRequality = false
    #if os(iOS)
    @State private var showFolderPicker = false
    #endif

    var body: some View {
        SettingsPage(title: "Downloads") {
            SettingsGroup(title: "Audio Quality") {
                SettingsPickerRow(id: "downloads.quality",
                                  title: "Download Quality",
                                  icon: "waveform",
                                  selection: Binding(get: { manager.downloadQuality },
                                                     set: { manager.downloadQuality = $0 }),
                                  options: DownloadQuality.allCases) { $0.title }

                // Named for the condition it fires on, because that's what makes
                // it obvious why it disappears below: Wi-Fi Only blocks metered
                // downloads outright (see `isConnectedForDownload`), so there is
                // no mobile-data download left for this to lower. A switch that
                // provably can't fire is worse than no switch.
                if !manager.downloadOnWifiOnly {
                    SettingsToggleRow(id: "downloads.autoAdjust",
                                      title: "Lower Quality on Mobile Data",
                                      subtitle: "Downloads drop one step below the quality above when you're off Wi-Fi.",
                                      icon: "antenna.radiowaves.left.and.right",
                                      isOn: Binding(get: { manager.autoAdjustQuality },
                                                    set: { manager.autoAdjustQuality = $0 }))
                }

                // Songs already on disk keep the quality they were written at,
                // so without this the picker looks broken to anyone whose
                // library was downloaded before they found it.
                if manager.offlineCount > 0 {
                    SettingsButtonRow(id: "downloads.redownload",
                                      title: "Re-download at This Quality",
                                      icon: "arrow.triangle.2.circlepath") {
                        confirmRequality = true
                    }
                }
            }

            SettingsGroup(title: "Automatic Downloads") {
                // "Imported" means arrived from outside — a file or folder
                // import, a Spotify transfer, a saved or restored share. It does
                // not mean "any new playlist", which would fire for every
                // playlist a fresh sign-in pulls down.
                //
                // What it switches on is the same standing choice the green
                // button on a playlist page makes, so it shows there afterwards
                // and can be switched off there one playlist at a time.
                SettingsToggleRow(id: "downloads.autoImported",
                                  title: "Keep Imported Playlists Offline",
                                  subtitle: "Playlists you import or save are downloaded automatically, including songs added to them later.",
                                  icon: "arrow.down.circle",
                                  isOn: Binding(get: { manager.autoDownloadImportedPlaylists },
                                                set: { manager.autoDownloadImportedPlaylists = $0 }))
            }

            // Not "downloads" in the keep-it-forever sense — these fill the
            // playback cache, which is temporary and evicted under a budget.
            // They live here anyway because what they cost is a download, and
            // this is the page someone opens when they're thinking about that.
            SettingsGroup(title: "Smooth Playback",
                          footer: "Songs are fetched before you reach them, so the queue plays without a pause between tracks. Fetched songs go to the playback cache, not your offline library.") {
                SettingsPickerRow(id: "downloads.queueDepth",
                                  title: "Download Ahead in the Queue",
                                  icon: "text.line.first.and.arrowtriangle.forward",
                                  selection: Binding(get: { prefetch.queueDepth },
                                                     set: { prefetch.queueDepth = $0 }),
                                  options: QueuePreloadDepth.allCases) { $0.title }

                SettingsToggleRow(id: "downloads.browsePrefetch",
                                  title: "Fetch While Browsing",
                                  subtitle: "Start fetching a song when you point at it or open the page it's on, so playing it is instant.",
                                  icon: "hand.point.up.left",
                                  isOn: Binding(get: { prefetch.prefetchWhileBrowsing },
                                                set: { prefetch.prefetchWhileBrowsing = $0 }))
            }

            SettingsGroup(title: "Network") {
                SettingsToggleRow(id: "downloads.wifiOnly",
                                  title: "Download on Wi-Fi Only",
                                  // Ethernet counts. The setting is about not
                                  // spending mobile data, and a Mac on a cable
                                  // isn't spending any — see `isUnmetered`.
                                  subtitle: "A wired connection counts as Wi-Fi.",
                                  icon: "wifi",
                                  isOn: Binding(get: { manager.downloadOnWifiOnly },
                                                set: { manager.downloadOnWifiOnly = $0 }))
            }

            LocalFilesSettingsGroup()

            SettingsGroup(title: "Files on Disk") {
                SettingsToggleRow(id: "downloads.fileCopy",
                                  title: "Also Keep a File Copy",
                                  subtitle: "Writes a named, taggable copy to the folder below.",
                                  icon: "square.and.arrow.down.on.square",
                                  isOn: Binding(get: { manager.keepFileCopyOnDownload },
                                                set: { manager.keepFileCopyOnDownload = $0 }))

                SettingsToggleRow(id: "downloads.metadataSync",
                                  title: "Update Files When Metadata Changes",
                                  icon: "tag",
                                  isOn: Binding(get: { manager.syncMetadataToDisk },
                                                set: { manager.syncMetadataToDisk = $0 }))

                SettingsRow(id: "downloads.exportLocation",
                            title: "Export Location",
                            icon: "folder") {
                    SettingsValue(text: exportManager.exportURLDisplayPath ?? "Not set",
                                  color: exportManager.exportURLDisplayPath == nil
                                         ? .mixTextTertiary : .mixTextSecondary)
                }

                SettingsButtonRow(title: "Change Location", icon: "arrow.right.circle") {
                    #if os(macOS)
                    FolderPickerHelper.show { url in
                        if let url { try? exportManager.setExportURL(url) }
                    }
                    #else
                    showFolderPicker = true
                    #endif
                }

                #if os(macOS)
                if let url = exportManager.exportURL {
                    SettingsButtonRow(title: "Open in Finder", icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif
            }
        }
        .alert("Re-download at \(manager.downloadQuality.title) quality?",
               isPresented: $confirmRequality) {
            Button("Cancel", role: .cancel) {}
            Button("Re-download") { manager.redownloadAllAtCurrentQuality() }
        } message: {
            Text("\(manager.offlineCount) song\(manager.offlineCount == 1 ? "" : "s") will be fetched again and stored at the quality above. They won't play offline until that finishes. Songs you imported yourself aren't touched.")
        }
        #if os(iOS)
        .sheet(isPresented: $showFolderPicker) {
            IOSFolderPicker { url in
                if let url { try? exportManager.setExportURL(url) }
            }
        }
        #endif
    }
}

// MARK: - Storage

struct StoragePane: View {

    @ObservedObject var manager: DownloadManager
    @EnvironmentObject private var deps: AppDependencies

    @State private var report = SettingsStorageReport.empty
    @State private var isMeasuring = true
    @ObservedObject private var lyricsStore = UserLyricsStore.shared

    @State private var confirmRemoveDownloads = false
    /// The list of songs whose lyrics the user wrote takes the whole pane when
    /// it's up, the same arrangement Connections uses for its sub-pages.
    @State private var showUserLyrics = false
    @State private var showMergeDuplicates = false
    /// Index into `budgetStops`, because a linear slider from 256 MB to 50 GB
    /// spends nine tenths of its travel on sizes nobody picks.
    @State private var budgetStop: Double = 0

    private static let budgetStops: [Int64] = {
        let gb = Int64(1_024 * 1_024 * 1_024)
        return [gb / 4, gb / 2, gb, 2 * gb, 4 * gb, 8 * gb, 16 * gb, 32 * gb, 50 * gb]
    }()

    private static func clampStop(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), budgetStops.count - 1)
    }

    /// The stop closest to what's stored, so the slider opens where the user
    /// left it even if the value was written by an older build.
    private static func nearestStop(to bytes: Int64) -> Double {
        let index = budgetStops.enumerated().min {
            abs($0.element - bytes) < abs($1.element - bytes)
        }?.offset ?? 0
        return Double(index)
    }

    var body: some View {
        Group {
            if showUserLyrics {
                UserLyricsPage { showUserLyrics = false }
                    .transition(.opacity)
            } else {
                pane
            }
        }
        .mixAnimation(.easeOut(duration: 0.18), value: showUserLyrics)
    }

    private var pane: some View {
        SettingsPage(title: "Storage", subtitle: storageSummary) {
            SettingsGroup(title: "Your Downloads") {
                SettingsRow(id: "storage.offline",
                            title: "Offline Downloads",
                            subtitle: offlineSubtitle,
                            icon: "arrow.down.circle") {
                    SettingsValue(text: SettingsStorageReport.format(report.offline))
                }

                if manager.offlineCount > 0 {
                    SettingsButtonRow(id: "storage.removeAll",
                                      title: "Remove All Downloads",
                                      icon: "trash",
                                      role: .destructive) {
                        confirmRemoveDownloads = true
                    }
                }
            }

            // Everything below is disposable — it re-fetches on demand. Grouped
            // apart from downloads for exactly that reason: one costs you
            // offline playback, the others cost you a moment's wait.
            SettingsGroup(title: "Caches") {
                cacheRow(id: "storage.playback",
                         title: "Playback Cache",
                         subtitle: "Songs kept after playing so they start instantly next time.",
                         icon: "music.note",
                         bytes: report.playback) {
                    _ = deps.onlineCoordinator.clearCache()
                    try? deps.fileStorage.clearLocalCache()
                }

                SettingsSliderRow(
                    id: "storage.budget",
                    title: "Cache Limit",
                    icon: "dial.medium",
                    value: $budgetStop,
                    range: 0...Double(Self.budgetStops.count - 1),
                    valueLabel: { SettingsStorageReport.format(Self.budgetStops[Self.clampStop($0)]) }
                )

                cacheRow(id: "storage.images",
                         title: "Images & Lyrics",
                         subtitle: "Artwork and lyrics fetched from the internet.",
                         icon: "photo",
                         bytes: report.images) {
                    let spotify = deps.spotifyClient
                    Task {
                        await spotify.clearImageCache()
                        await MainActor.run {
                            LyricsService.shared.clearCache()
                            URLCache.shared.removeAllCachedResponses()
                        }
                    }
                }
            }

            // Also not a cache: text the user typed, which no lookup will ever
            // hand back. It sits beside the library group for that reason —
            // clearing it costs something that can't be re-fetched.
            if lyricsStore.count > 0 {
                SettingsGroup(title: "Your Lyrics",
                              footer: "Lyrics you added yourself, for songs the app couldn't find or got wrong. They're kept on this device and shown instead of any lyrics found online.") {
                    // A count is the one thing the person who typed these
                    // already knows. What they can't do from a count is go back
                    // to the one they got wrong, so the row opens the list.
                    SettingsButtonRow(id: "storage.userLyrics",
                                      title: "Your Lyrics",
                                      subtitle: "\(lyricsStore.count) song\(lyricsStore.count == 1 ? "" : "s")",
                                      icon: "text.quote",
                                      role: .plain,
                                      showsChevron: true,
                                      action: { showUserLyrics = true }) {
                        SettingsValue(text: SettingsStorageReport.format(lyricsStore.totalBytes))
                    }
                }
            }

            // Not a cache: this is the user's own library, and the only thing
            // that undoes an import that ran before duplicates were caught on
            // the way in.
            SettingsGroup(title: "Library",
                          footer: "Songs you already owned can end up in your library twice after importing a playlist. This finds them and keeps one copy of each — you see the list before anything is removed.") {
                SettingsButtonRow(id: "storage.mergeDuplicates",
                                  title: "Merge Duplicate Songs…",
                                  icon: "square.on.square.dashed") {
                    showMergeDuplicates = true
                }
            }
        }
        .task(id: manager.offlineCount) { await measure() }
        .onAppear { budgetStop = Self.nearestStop(to: PlaybackCache.budgetBytes) }
        .onChange(of: budgetStop) { _, new in
            PlaybackCache.budgetBytes = Self.budgetStops[Self.clampStop(new)]
            // Lowering the limit should take effect now, not at the end of the
            // next download — otherwise the number above the slider disagrees
            // with the number in the row right beside it.
            Task {
                await Task.detached(priority: .utility) { PlaybackCache.enforceBudget() }.value
                await measure()
            }
        }
        .alert("Remove all downloads?", isPresented: $confirmRemoveDownloads) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                manager.removeAllDownloads()
                Task { await measure() }
            }
        } message: {
            Text("\(manager.offlineCount) song\(manager.offlineCount == 1 ? "" : "s") will need the network again. Any file copies in your export folder are kept, and songs you imported yourself aren't touched.")
        }
        .sheet(isPresented: $showMergeDuplicates) {
            MergeDuplicatesSheet().environmentObject(deps)
        }
    }

    /// A measured bucket with a Clear button that re-measures when it's done.
    private func cacheRow(id: String,
                          title: String,
                          subtitle: String,
                          icon: String,
                          bytes: Int64,
                          clear: @escaping () -> Void) -> some View {
        SettingsRow(id: id, title: title, subtitle: subtitle, icon: icon) {
            HStack(spacing: 10) {
                SettingsValue(text: SettingsStorageReport.format(bytes))
                SettingsInlineButton(title: "Clear", isEnabled: bytes > 0) {
                    clear()
                    Task { await measure() }
                }
            }
        }
    }

    private var storageSummary: String {
        isMeasuring
            ? "Measuring…"
            : "Mixtape is using \(SettingsStorageReport.format(report.total)) on this device."
    }

    private var offlineSubtitle: String {
        let count = manager.offlineCount
        guard count > 0 else { return "Nothing downloaded yet." }
        return "\(count) song\(count == 1 ? "" : "s") available with no network."
    }

    private func measure() async {
        isMeasuring = true
        report = await SettingsStorageReport.measure(offlineBytes: manager.offlineBytes)
        isMeasuring = false
    }
}

// MARK: - Sync

struct SyncPane: View {

    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        SettingsPage(title: "Sync") {
            SettingsGroup {
                SettingsRow(id: "sync.status", title: "Status", icon: MixtapeIcons.sync) {
                    statusBadge
                }

                SettingsButtonRow(id: "sync.now",
                                  title: "Sync Now",
                                  icon: MixtapeIcons.syncing) {
                    Task { await vm.triggerSync() }
                }

                SettingsButtonRow(id: "sync.full",
                                  title: "Re-sync Everything",
                                  subtitle: "Fetches every record from the server, not just recent changes. Nothing is deleted.",
                                  icon: MixtapeIcons.sync) {
                    Task { await vm.resyncFromServer() }
                }

                if vm.isFindingCovers {
                    SettingsBusyRow(title: "Looking for missing covers…")
                } else {
                    SettingsButtonRow(id: "sync.covers",
                                      title: "Find Missing Covers",
                                      subtitle: vm.findCoversResult
                                          ?? "Looks up artwork for songs that don't have any. Syncing can't: it only moves covers a device already had.",
                                      icon: "photo.on.rectangle.angled") {
                        Task { await vm.findMissingCovers(using: deps.itunesClient) }
                    }
                }

                if vm.isUpgradingCovers {
                    SettingsBusyRow(title: "Fetching full-size covers…")
                } else {
                    SettingsButtonRow(id: "sync.coverQuality",
                                      title: "Upgrade Cover Quality",
                                      subtitle: vm.upgradeCoversResult
                                          ?? "Fetches covers again for songs whose artwork was saved at a smaller size — the usual cause of a blurry cover.",
                                      icon: "sparkles.rectangle.stack") {
                        Task { await vm.upgradeCoverQuality(using: deps.itunesClient) }
                    }
                }

                if vm.isRestoringSongs {
                    SettingsBusyRow(title: "Restoring missing songs…")
                } else {
                    SettingsButtonRow(id: "sync.restore",
                                      title: "Restore Missing Songs",
                                      subtitle: vm.restoreSongsResult
                                          ?? "Use this if a playlist says it has more songs than it shows. Brings back anything an out-of-date deletion on the server removed by mistake.",
                                      icon: "arrow.uturn.backward.circle") {
                        Task { await vm.restoreMissingSongs() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch vm.syncState {
        case .idle:
            SettingsValue(text: "Idle", color: .mixTextTertiary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                SettingsValue(text: "Syncing", color: .mixSyncPending)
            }
        case .upToDate(let date):
            SettingsValue(text: "Up to date · \(date.formatted(.relative(presentation: .named)))",
                          color: .mixSyncSynced)
        case .pendingChanges(let count):
            SettingsValue(text: "\(count) pending", color: .mixSyncPending)
        case .error(let message):
            SettingsValue(text: message, color: .mixSyncConflict)
        }
    }
}

// MARK: - Connections

struct ConnectionsPane: View {

    @ObservedObject var vm: SettingsViewModel

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var route = SettingsRoute.shared

    @ObservedObject private var scrobbler = LastFmScrobbler.shared
    @State private var showLastFm = false
    /// The Spotify library picker takes the whole pane when it's up, rather
    /// than opening a window over the app. See SpotifyConnectionView.
    @State private var showSpotifyLibrary = false
    /// Same arrangement for choosing which favourites to push. Two flags rather
    /// than one enum because they are never both up, and the pane reads more
    /// plainly as a list of things that can replace it.
    @State private var showSpotifyLikesPush = false

    #if os(iOS)
    @EnvironmentObject private var resolverStatus: ResolverStatusService
    @AppStorage(RemoteResolverService.baseURLDefaultsKey) private var resolverURLString = ""
    @State private var resolverTesting = false
    @State private var resolverTestResult: ResolverTestResult?
    @State private var showResolverAdvanced = false
    #endif

    var body: some View {
        Group {
            if showSpotifyLibrary {
                SpotifyLibraryPage(spotifyClient: deps.spotifyClient,
                                   importService: deps.spotifyImportService,
                                   auth: deps.spotifyAuth,
                                   followService: deps.spotifyFollowService,
                                   ledger: deps.spotifyImportLedger) {
                    showSpotifyLibrary = false
                }
                .transition(.opacity)
            } else if showSpotifyLikesPush {
                SpotifyLikesPushPage(service: deps.spotifyExportService) {
                    showSpotifyLikesPush = false
                }
                .transition(.opacity)
            } else {
                pane
            }
        }
        .mixAnimation(.easeOut(duration: 0.18), value: showSpotifyLibrary)
        .mixAnimation(.easeOut(duration: 0.18), value: showSpotifyLikesPush)
        // Arriving here from "Import Spotify Library" elsewhere in the app:
        // SettingsView has already selected this pane, and the last step is
        // ours. See SettingsRoute.
        .onAppear {
            guard route.request?.opensSpotifyLibrary == true else { return }
            showSpotifyLibrary = true
            route.consume()
        }
    }

    private var pane: some View {
        SettingsPage(title: "Connections") {
            // Spotify first: it's the connection that brings music in, and the
            // one most people are here for.
            SpotifyConnectionGroup(auth: deps.spotifyAuth,
                                   openLibrary: { showSpotifyLibrary = true },
                                   openLikesPush: { showSpotifyLikesPush = true })

            SettingsGroup(title: "Last.fm",
                          footer: "Connect with your own Last.fm API key to scrobble what you play.") {
                SettingsButtonRow(id: "connections.lastfm",
                                  title: "Account",
                                  icon: "person.badge.key",
                                  role: .plain,
                                  showsChevron: true) {
                    showLastFm = true
                } trailing: {
                    SettingsValue(text: scrobbler.isConfigured
                                  ? (scrobbler.username ?? "Connected")
                                  : "Not connected",
                                  color: scrobbler.isConfigured ? .mixSuccess : .mixTextTertiary)
                }

                SettingsToggleRow(id: "connections.scrobble",
                                  title: "Scrobble What I Play",
                                  icon: "dot.radiowaves.left.and.right",
                                  isOn: $scrobbler.isEnabled,
                                  isEnabled: scrobbler.isConfigured)
            }

            #if os(iOS)
            streamingGroup
            #endif
        }
        .sheet(isPresented: $showLastFm) {
            LastFmConnectView()
        }
        #if os(iOS)
        .task { await resolverStatus.refresh() }
        #endif
    }

    #if os(iOS)
    /// iOS can't run yt-dlp, so Discover playback goes through a resolver server
    /// (a Mac on the network, or the hosted one). This is where you find out
    /// whether that's working.
    @ViewBuilder
    private var streamingGroup: some View {
        SettingsGroup(title: "Streaming") {
            SettingsRow(id: "connections.streaming",
                        title: resolverStatusTitle,
                        icon: "antenna.radiowaves.left.and.right") {
                if resolverStatus.status == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .fill(resolverStatusColor)
                        .frame(width: 9, height: 9)
                }
            }

            SettingsRow(title: resolverTesting ? "Testing…" : "Test Connection",
                        subtitle: resolverTesting ? nil : resolverTestResult?.message,
                        icon: "bolt.horizontal.circle") {
                if resolverTesting {
                    ProgressView().controlSize(.small)
                } else if let result = resolverTestResult {
                    Image(systemName: result.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(result.tint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    SettingsInlineButton(title: "Test") { runResolverTest() }
                }
            }

            // Developer-only manual override, gated by the same Supabase role as
            // Developer Tools. The bearer token is never sent to a typed address
            // (see RemoteResolverService).
            if vm.isDeveloper {
                DisclosureGroup(isExpanded: $showResolverAdvanced) {
                    HStack(spacing: 10) {
                        Text("Resolver")
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                        Spacer(minLength: 8)
                        TextField("Default (hosted)", text: $resolverURLString)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                            .onChange(of: resolverURLString) { _, _ in
                                Task { await resolverStatus.refresh() }
                            }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Advanced")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .tint(Color.mixTextSecondary)
                .padding(.horizontal, SettingsMetrics.rowPadH)
                .padding(.vertical, SettingsMetrics.rowPadV)
            }
        }
    }

    private func runResolverTest() {
        resolverTesting = true
        resolverTestResult = nil
        Task {
            // Keep the spinner up long enough to read even when the health
            // check returns near-instantly.
            async let probe = resolverStatus.refresh()
            try? await Task.sleep(for: .milliseconds(450))
            let source = await probe
            withMixAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                resolverTesting = false
                resolverTestResult = source != nil
                    ? .success("Connected — streaming is working.")
                    : .failure("Couldn't connect. Check your internet and try again.")
            }
            try? await Task.sleep(for: .seconds(5))
            if !resolverTesting {
                withMixAnimation { resolverTestResult = nil }
            }
        }
    }

    private var resolverStatusTitle: String {
        switch resolverStatus.status {
        case .checking: return "Checking…"
        case .online:
            // End users just see "Connected"; developers see which source.
            if vm.isDeveloper, let name = resolverStatus.activeSource?.displayName {
                return "Connected via \(name)"
            }
            return "Connected"
        case .offline: return "Not connected"
        }
    }

    private var resolverStatusColor: Color {
        switch resolverStatus.status {
        case .checking: return .mixTextSecondary
        case .online:   return .mixSuccess
        case .offline:  return .mixDestructive
        }
    }
    #endif
}

#if os(iOS)
/// Result of a manual "Test Connection" tap.
enum ResolverTestResult {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let m), .failure(let m): return m
        }
    }
    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .success: return .mixSuccess
        case .failure: return .mixDestructive
        }
    }
}
#endif

// MARK: - About

struct AboutPane: View {

    #if os(macOS)
    // When ON, Sparkle subscribes to the "beta" channel and receives opt-in
    // development builds ahead of stable. Read by UpdaterController via the
    // same key.
    @AppStorage(UpdaterController.receiveDevelopmentBuildsKey) private var receiveDevelopmentBuilds = false
    #endif

    var body: some View {
        SettingsPage(title: "About") {
            SettingsGroup {
                SettingsRow(id: "about.version", title: "Version", icon: "info.circle") {
                    SettingsValue(text: displayVersion, color: .mixTextTertiary)
                }
                SettingsRow(title: "Build", icon: "hammer") {
                    SettingsValue(text: buildNumber, color: .mixTextTertiary)
                }
            }

            SettingsGroup {
                SettingsLinkRow(id: "about.changelog", title: "What's New",
                                icon: "sparkles", url: MixtapeLink.web("changelog"))
                SettingsLinkRow(id: "about.help", title: "Help",
                                icon: "questionmark.circle", url: MixtapeLink.web("help"))
                SettingsLinkRow(id: "about.terms", title: "Terms of Service",
                                icon: "doc.text", url: MixtapeLink.web("terms"))
            }

            #if os(macOS)
            SettingsGroup(title: "Updates",
                          footer: "Development builds arrive earlier and may be less stable.") {
                SettingsToggleRow(id: "about.betaChannel",
                                  title: "Receive Development Builds",
                                  icon: "hammer.circle",
                                  isOn: $receiveDevelopmentBuilds)
            }
            #endif
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// On macOS dev-channel builds this reads e.g. "2.0.0 (beta)".
    private var displayVersion: String {
        #if os(macOS)
        return receiveDevelopmentBuilds ? "\(appVersion) (beta)" : appVersion
        #else
        return appVersion
        #endif
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Developer

struct DeveloperPane: View {

    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SettingsPage(title: "Developer",
                     subtitle: "These act on the server and every signed-in device.") {
            SettingsGroup(title: "Maintenance") {
                if vm.isRebuilding {
                    SettingsBusyRow(title: "Rebuilding artist & album groupings…")
                } else {
                    SettingsButtonRow(title: "Rebuild Library Groupings",
                                      icon: "arrow.triangle.2.circlepath") {
                        Task { await vm.rebuildGroupings() }
                    }
                }
            }
        }
    }
}

// MARK: - Danger Zone

/// Everything that loses something for good lives here and nowhere else, so no
/// ordinary page carries a red button you could hit while changing a toggle.
/// Ordered by reach: this device, then the library on every device, then the
/// account. Deleting the account finishes on mixtaped.tech — the one place it's
/// implemented, next to the data export you'd want to run first.
struct DangerZonePane: View {

    @ObservedObject var vm: SettingsViewModel

    @EnvironmentObject private var deps:  AppDependencies
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.openURL) private var openURL
    @ObservedObject private var lyricsStore = UserLyricsStore.shared

    @State private var confirmResetSettings    = false
    @State private var confirmRemoveLyrics     = false
    @State private var confirmSignOutEverywhere = false
    @State private var confirmDeleteAccount    = false

    private var handle: String {
        vm.currentUser.map { "@\($0.username ?? $0.displayName)" } ?? "this account"
    }

    var body: some View {
        SettingsPage(title: "Danger Zone",
                     subtitle: "Nothing here can be undone. Everything asks first.") {
            SettingsGroup(title: "This Device",
                          footer: "Only this device. Your account and synced library aren't touched.") {
                SettingsButtonRow(id: "danger.resetSettings",
                                  title: "Reset All Settings",
                                  subtitle: "Appearance, playback, downloads and the equalizer go back to their defaults.",
                                  icon: "arrow.counterclockwise",
                                  role: .destructive) {
                    confirmResetSettings = true
                }
                if lyricsStore.count > 0 {
                    SettingsButtonRow(id: "danger.removeLyrics",
                                      title: "Remove All Your Lyrics",
                                      subtitle: "Lyrics you added for \(lyricsStore.count) song\(lyricsStore.count == 1 ? "" : "s").",
                                      icon: "text.quote",
                                      role: .destructive) {
                        confirmRemoveLyrics = true
                    }
                }
            }

            SettingsGroup(title: "Your Library",
                          footer: "Deleted from the server and from every device signed in as \(handle).") {
                if vm.isResettingStats {
                    SettingsBusyRow(title: "Clearing listening history…")
                } else {
                    SettingsButtonRow(id: "danger.resetHistory",
                                      title: "Reset Listening History",
                                      subtitle: "Top artists, top songs and minutes go back to zero. Your music stays.",
                                      icon: "chart.bar.xaxis",
                                      role: .destructive) {
                        vm.showResetStatsConfirm = true
                    }
                }
                if let error = vm.resetStatsError { SettingsErrorRow(message: error) }

                // Only when there is something to clean. Deleting a playlist
                // takes its orphans with it now, so for most libraries this
                // row never appears — it exists for the ones stranded before
                // that was true.
                if vm.orphanCount > 0 {
                    if vm.isCleaningOrphans {
                        SettingsBusyRow(title: "Removing songs…")
                    } else {
                        SettingsButtonRow(id: "danger.cleanOrphans",
                                          title: "Remove Leftover Songs",
                                          subtitle: "\(vm.orphanCount) song\(vm.orphanCount == 1 ? "" : "s") from playlists you deleted, in no other playlist and not liked.",
                                          icon: "sparkles",
                                          role: .destructive) {
                            vm.showCleanOrphansConfirm = true
                        }
                    }
                }

                if vm.isDeletingPlaylists {
                    SettingsBusyRow(title: "Deleting playlists…")
                } else {
                    SettingsButtonRow(id: "danger.deletePlaylists",
                                      title: "Delete All Playlists",
                                      subtitle: "Playlists you made. Songs, All Songs and Liked Songs stay.",
                                      icon: "music.note.list",
                                      role: .destructive) {
                        vm.showDeletePlaylistsConfirm = true
                    }
                }
                if let error = vm.deletePlaylistsError { SettingsErrorRow(message: error) }

                if vm.isDeletingTracks {
                    SettingsBusyRow(title: "Deleting music…")
                } else {
                    SettingsButtonRow(id: "danger.deleteMusic",
                                      title: "Delete All Music",
                                      subtitle: "Every song, album and artist. Playlists stay, empty.",
                                      icon: "music.note.slash",
                                      role: .destructive) {
                        vm.showDeleteTracksConfirm = true
                    }
                }
                if let error = vm.deleteTracksError { SettingsErrorRow(message: error) }

                if vm.isClearing {
                    SettingsBusyRow(title: "Clearing everything…")
                } else {
                    SettingsButtonRow(id: "danger.clearEverything",
                                      title: "Clear Everything",
                                      subtitle: "All of the above, plus liked songs and downloads. Your account stays.",
                                      icon: MixtapeIcons.delete,
                                      role: .destructive) {
                        vm.showClearLibraryConfirm = true
                    }
                }
                if let error = vm.clearError { SettingsErrorRow(message: error) }
            }

            SettingsGroup(title: "Your Account",
                          footer: "Deleting your account finishes on mixtaped.tech, where you can download a copy of your data first.") {
                SettingsButtonRow(id: "danger.signOutEverywhere",
                                  title: "Sign Out Everywhere",
                                  subtitle: "Every device and browser, this one included, has to sign in again.",
                                  icon: MixtapeIcons.signOut,
                                  role: .destructive) {
                    confirmSignOutEverywhere = true
                }
                SettingsButtonRow(id: "danger.deleteAccount",
                                  title: "Delete Account…",
                                  subtitle: "Your profile, library, playlists, history and uploads, for good.",
                                  icon: "person.crop.circle.badge.xmark",
                                  role: .destructive,
                                  action: { confirmDeleteAccount = true }) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .confirmationDialog("Reset All Settings",
                            isPresented: $confirmResetSettings,
                            titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) {
                SettingsReset.restoreDefaults(deps: deps, theme: theme)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default, including appearance, playback, downloads, and the equalizer. Your music, playlists, downloaded songs, and Last.fm connection are left alone.")
        }
        .confirmationDialog("Remove Your Lyrics",
                            isPresented: $confirmRemoveLyrics,
                            titleVisibility: .visible) {
            Button("Remove Lyrics", role: .destructive) { lyricsStore.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The lyrics you added for \(lyricsStore.count) song\(lyricsStore.count == 1 ? "" : "s") will be deleted. Those songs go back to whatever the app can find online, which for most of them is nothing.")
        }
        .confirmationDialog("Reset Listening History",
                            isPresented: $vm.showResetStatsConfirm,
                            titleVisibility: .visible) {
            Button("Reset History", role: .destructive) { Task { await vm.resetListeningStats() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every play is forgotten: top artists, top songs and minutes all go back to zero, here and on your public profile. Your music, playlists and liked songs are untouched.")
        }
        .confirmationDialog("Remove Leftover Songs",
                            isPresented: $vm.showCleanOrphansConfirm,
                            titleVisibility: .visible) {
            Button("Remove \(vm.orphanCount) Song\(vm.orphanCount == 1 ? "" : "s")", role: .destructive) {
                Task { await vm.cleanUpOrphanedSongs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These songs came from playlists you deleted and nothing else in your library holds them — they're in no playlist and not liked. Deleting a playlist takes them with it now; this clears the ones left over from before.")
        }
        .confirmationDialog("Delete All Playlists",
                            isPresented: $vm.showDeletePlaylistsConfirm,
                            titleVisibility: .visible) {
            Button("Delete All Playlists", role: .destructive) { Task { await vm.deleteAllUserPlaylists() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your created playlists will be permanently deleted from every device. All Songs and Liked Songs will remain. Your music is unaffected.")
        }
        .confirmationDialog("Delete All Music",
                            isPresented: $vm.showDeleteTracksConfirm,
                            titleVisibility: .visible) {
            Button("Delete All Music", role: .destructive) { Task { await vm.deleteAllTracks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All tracks, albums, and artists will be permanently deleted from every device. Your playlists will remain but be empty.")
        }
        .confirmationDialog("Clear Everything",
                            isPresented: $vm.showClearLibraryConfirm,
                            titleVisibility: .visible) {
            Button("Clear Everything", role: .destructive) { Task { await vm.clearLibrary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all music, albums, artists, playlists, liked songs, files and listening history — from the server and every device — and empties your public profile. Your account itself stays.")
        }
        .confirmationDialog("Sign Out Everywhere",
                            isPresented: $confirmSignOutEverywhere,
                            titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { Task { await vm.signOutEverywhere() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device and browser signed in as \(handle) is signed out, including this one. Your library is kept.")
        }
        .confirmationDialog("Delete \(handle)?",
                            isPresented: $confirmDeleteAccount,
                            titleVisibility: .visible) {
            Button("Continue on mixtaped.tech") {
                openURL(MixtapeLink.web("account", focus: "danger.deleteAccount"))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account is deleted on the website, where you'll confirm once more. Download your data there first if you want a copy — once it's gone it can't be recovered. Make sure the site is signed in as \(handle).")
        }
        .task { vm.refreshOrphanCount() }
    }
}
