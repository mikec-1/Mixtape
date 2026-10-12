// One view per settings category. Each pane owns its own sheets and confirmations;
// the shell only picks which pane is on screen.

import SwiftUI
import UserNotifications
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
    @AppStorage(Analytics.optInKey) private var helpImprove = false
    @State private var showFindPeople = false
    #if os(iOS)
    @State private var showAccount = false
    @State private var showMyProfile = false
    #endif

    /// The real `profiles` row once it arrives. The page opens on the local guess and corrects itself.
    @State private var resolvedProfile: UserProfile?

    /// The signed-in user as a `profiles` row.
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
                        AvatarView(url: user.avatarURL, seed: user.username ?? user.displayName, size: 56)
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
                // Shows the same page everyone else sees.
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
                SettingsToggleRow(id: "account.analytics",
                                  title: "Help Improve Mixtape",
                                  subtitle: "Sends which songs you skip and which searches find nothing. Off by default.",
                                  icon: "chart.bar",
                                  isOn: $helpImprove)
                    .onChange(of: helpImprove) { _, on in
                        Task { await deps.authService.updateAnalyticsOptIn(on) }
                    }
            }

            // Account housekeeping the website owns, also reached from the avatar menu.
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
            // Profiles open as a page in the main window, so the sheet hands the choice back and closes.
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
        .mixConfirmationDialog("Sign Out", isPresented: $vm.showSignOutConfirm, titleVisibility: .visible) {
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
    @AppStorage(NowPlayingSurfaces.liveActivityKey) private var liveActivity = false
    #endif
    #if os(macOS)
    @StateObject private var launchAtLogin = LaunchAtLogin.shared
    @AppStorage(MacMenuBarPlayer.visibleKey) private var showsMenuBarPlayer = true
    /// The value waiting on the restart prompt.
    @State private var accelerationChange: Bool?
    #else
    @AppStorage(HardwareAcceleration.key) private var hardwareAcceleration = true
    #endif
    var body: some View {
        SettingsPage(title: "General") {
            SettingsGroup(title: "Appearance") {
                SettingsPickerRow(id: "general.appearance",
                                  title: "Theme",
                                  icon: "circle.lefthalf.filled",
                                  selection: $theme.appearance,
                                  options: AppAppearance.allCases) { $0.title }
                    // Observed directly: the macOS pop-up keeps its old styling across an appearance flip.
                    .id(theme.appearance)
            }

            SettingsGroup(title: "Background") {
                SettingsRow(id: "general.backdrop",
                            title: "Background Colour",
                            subtitle: "Mixes a colour into the background of the whole app.",
                            icon: "paintpalette") {
                    ColorPicker("Background Colour", selection: backdropColour, supportsOpacity: false)
                        .labelsHidden()
                }
                BackdropSwatches(theme: theme)
                if theme.backdrop != nil {
                    SettingsPickerRow(id: "general.backdropMotion",
                                      title: "Movement",
                                      subtitle: "Floating lets the colour drift around and off the edges.",
                                      icon: "wind",
                                      selection: backdropMotion,
                                      options: BackdropMotion.allCases) { $0.title }
                }
            }

            SettingsGroup(title: "Interface", footer: theme.preset.detail) {
                // The preset first, then the three axes for anyone who wants one without the others.
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

                SettingsPickerRow(id: "general.importsTo",
                                  title: "Add Imported Songs To",
                                  subtitle: "Songs from your files, YouTube and Spotify links. All Songs doesn't like them.",
                                  icon: "square.and.arrow.down",
                                  selection: $meta.importDestination,
                                  options: ImportDestination.allCases) { $0.title }
            }

            SettingsGroup(title: "Notifications") {
                NotificationToggleRow()
            }

            #if os(iOS)
            SettingsGroup(title: "Interaction") {
                SettingsToggleRow(id: "general.haptics",
                                  title: "Haptic Feedback",
                                  icon: "hand.tap",
                                  isOn: $hapticsEnabled)
            }

            SettingsGroup(title: "Lock Screen",
                          footer: "iOS already shows the song on the Lock Screen and in the Dynamic Island. "
                                + "The Live Activity adds Mixtape's own tile beside it.") {
                SettingsToggleRow(id: "general.liveActivity",
                                  title: "Live Activity",
                                  icon: "platter.filled.bottom.iphone",
                                  isOn: $liveActivity)
            }
            #endif

            #if os(macOS)
            SettingsGroup(title: "Menu Bar") {
                SettingsToggleRow(id: "general.menuBarPlayer",
                                  title: "Show Mini Player in Menu Bar",
                                  icon: "menubar.rectangle",
                                  isOn: $showsMenuBarPlayer)
            }

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

            #if os(macOS)
            SettingsGroup(title: "Compatibility") {
                SettingsToggleRow(id: "general.hardwareAcceleration",
                                  title: "Hardware Acceleration",
                                  subtitle: "Uses the GPU to draw backgrounds and effects and to split stems. "
                                          + "Turn it off if Mixtape flickers or draws glitches.",
                                  icon: "cpu",
                                  isOn: Binding(get: { HardwareAcceleration.isOn },
                                                set: { accelerationChange = $0 }))
            }
            #else
            SettingsGroup(title: "Compatibility",
                          footer: hardwareAcceleration == HardwareAcceleration.isOn ? nil
                                : "Takes effect the next time Mixtape opens.") {
                SettingsToggleRow(id: "general.hardwareAcceleration",
                                  title: "Hardware Acceleration",
                                  subtitle: "Uses the GPU to draw backgrounds and effects. "
                                          + "Turn it off if Mixtape flickers or draws glitches.",
                                  icon: "cpu",
                                  isOn: $hardwareAcceleration)
            }
            #endif
        }
        #if os(macOS)
        .onAppear { launchAtLogin.refresh() }
        .mixConfirmationDialog("Restart Mixtape?",
                               isPresented: Binding(get: { accelerationChange != nil },
                                                    set: { if !$0 { accelerationChange = nil } }),
                               titleVisibility: .visible,
                               presenting: accelerationChange) { on in
            Button("Restart") { HardwareAcceleration.restart(on: on) }
            Button("Cancel", role: .cancel) {}
        } message: { on in
            Text("Hardware acceleration turns \(on ? "on" : "off") when Mixtape restarts.")
        }
        #endif
    }

    /// Custom is only listed when the axes already match it; a Picker with an unlisted selection draws blank.
    private var presetOptions: [MixAppearancePreset] {
        theme.preset == .custom ? MixAppearancePreset.allCases
                                : MixAppearancePreset.selectable
    }

    /// Unset shows the brand orange, so opening the picker starts somewhere.
    private var backdropColour: Binding<Color> {
        Binding(get: { theme.backdrop.map { Color(hex: $0.hex) } ?? BrandAccent.color },
                set: { theme.backdrop = MixBackdrop(hex: MixBackdrop.hex(of: $0),
                                                    motion: theme.backdrop?.motion ?? .still) })
    }

    private var backdropMotion: Binding<BackdropMotion> {
        Binding(get: { theme.backdrop?.motion ?? .still },
                set: { motion in
                    guard let hex = theme.backdrop?.hex else { return }
                    theme.backdrop = MixBackdrop(hex: hex, motion: motion)
                })
    }
}

/// Banners on this device. Turning it on asks the system, or opens its settings when they're blocked there.
private struct NotificationToggleRow: View {

    @AppStorage(InviteNotifier.enabledKey) private var enabled = false
    @State private var blocked = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsToggleRow(id: "general.notifications",
                          title: "Notifications",
                          subtitle: blocked ? "Turned off in \(Self.settingsName)."
                                            : "Messages, Jams near you, new releases and your recap.",
                          icon: "bell",
                          isOn: Binding(get: { enabled }, set: { on in
                              guard on else { return InviteNotifier.shared.disable() }
                              enabled = true
                              Task {
                                  if await !InviteNotifier.shared.enable(), let url = InviteNotifier.systemSettingsURL {
                                      openURL(url)
                                  }
                                  await load()
                              }
                          }))
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: Self.becameActive)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        blocked = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        if blocked { enabled = false }
    }

    #if os(macOS)
    private static let settingsName = "System Settings"
    private static let becameActive = NSApplication.didBecomeActiveNotification
    #else
    private static let settingsName = "Settings"
    private static let becameActive = UIApplication.didBecomeActiveNotification
    #endif
}

/// None plus the preset colours, one tap each.
private struct BackdropSwatches: View {

    @ObservedObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 8) {
            swatch(name: "No Colour", hex: nil)
            ForEach(MixBackdrop.presets, id: \.1) { swatch(name: $0.0, hex: $0.1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.rowPadH)
        .padding(.vertical, SettingsMetrics.rowPadV)
    }

    private func swatch(name: String, hex: String?) -> some View {
        let selected = theme.backdrop?.hex == hex
        return Button {
            theme.backdrop = hex.map { MixBackdrop(hex: $0, motion: theme.backdrop?.motion ?? .still) }
        } label: {
            Circle()
                .fill(hex.map { Color(hex: $0) } ?? Color.mixSurface2)
                .overlay {
                    if hex == nil {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                }
                .frame(width: 24, height: 24)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.mixTextPrimary : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Playback

struct PlaybackPane: View {

    // Passed in because only these two republish; a picker bound through `deps` goes stale.
    @ObservedObject var engine:    PlaybackEngine
    @ObservedObject var equalizer: AudioEqualizer
    @AppStorage("playback.crossfadeOnSkip") private var crossfadeOnSkip = false
    @AppStorage("playback.normalizeVolume") private var normalizeVolume = true
    @AppStorage("playback.trimPadding")     private var trimPadding = true
    @AppStorage("playback.autoplay")        private var autoplay = true
    @AppStorage("playback.smartShuffle")    private var smartShuffle = false

    /// Counted on appear: both lists are written from context menus elsewhere.
    @State private var hiddenCount  = SuggestionFeedback.hiddenSongs.count
    @State private var blockedCount = SuggestionFeedback.blockedArtists.count

    /// A private session is stored as an expiry, so this reflects whether one is running.
    @State private var privateSession = PrivateSession.isActive

    #if os(iOS)
    @State private var showEqualizer = false
    #endif

    /// Same key as `ResolverPreferences.preferCensored`. The resolvers read the default directly.
    @AppStorage("mixtape.resolver.preferCensored") private var preferCensored = false

    /// The player's own speed menu can land between these, so the row snaps to the nearest.
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

    /// "2 songs and 1 artist", with correct plurals.
    private var suggestionFeedbackSubtitle: String {
        func part(_ count: Int, _ noun: String) -> String? {
            count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        let parts = [part(hiddenCount, "song"), part(blockedCount, "artist")].compactMap { $0 }
        return parts.joined(separator: " and ") + " won't be suggested in mixes or autoplay"
    }

    private var privateSessionSubtitle: String {
        guard privateSession, let ends = PrivateSession.expiry else {
            return "Play without it counting toward your history, stats or mixes"
        }
        return "Nothing is being logged. Ends at \(ends.formatted(date: .omitted, time: .shortened))."
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
                    SettingsToggleRow(id: "playback.crossfadeOnSkip",
                                      title: "Crossfade on Skip",
                                      subtitle: "Blend into the next song when you skip mid-song, too",
                                      icon: "forward.end",
                                      isOn: $crossfadeOnSkip)
                }
            }

            SettingsGroup(title: "Sound") {
                SettingsToggleRow(id: "playback.normalizeVolume",
                                  title: "Normalize Volume",
                                  subtitle: "Even out the level between songs, so one loud rip doesn't jump out of the queue",
                                  icon: "waveform",
                                  isOn: $normalizeVolume)
                SettingsToggleRow(id: "playback.trimPadding",
                                  title: "Trim Trailing Silence",
                                  subtitle: "Skip the dead air some uploads leave after the song has finished",
                                  icon: "scissors",
                                  isOn: $trimPadding)
            }

            SettingsGroup(title: "Queue") {
                SettingsToggleRow(id: "playback.autoplay",
                                  title: "Autoplay",
                                  subtitle: "When a list ends, keep going with songs like the ones you were playing",
                                  icon: "infinity",
                                  isOn: $autoplay)
                SettingsToggleRow(id: "playback.smartShuffle",
                                  title: "Smart Shuffle",
                                  subtitle: "Mix songs from your library that aren\u{2019}t in the list into a shuffled playlist",
                                  icon: "shuffle.circle",
                                  isOn: $smartShuffle)
            }

            // Hidden when nothing is hidden.
            if hiddenCount > 0 || blockedCount > 0 {
                SettingsGroup(title: "Suggestions") {
                    SettingsButtonRow(id: "playback.suggestionFeedback",
                                      title: "Show These Again",
                                      subtitle: suggestionFeedbackSubtitle,
                                      icon: "eye",
                                      role: .destructive) {
                        SuggestionFeedback.clear()
                        hiddenCount = 0
                        blockedCount = 0
                    }
                }
            }

            SettingsGroup(title: "Privacy",
                          footer: "A private session ends on its own after six hours.") {
                SettingsToggleRow(id: "playback.privateSession",
                                  title: "Private Session",
                                  subtitle: privateSessionSubtitle,
                                  icon: "eye.slash",
                                  isOn: $privateSession)
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
            // Inline on macOS. It has its own header, so it gets a card border instead of a SettingsGroup.
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
        .onChange(of: privateSession) { _, on in PrivateSession.set(on) }
        .onChange(of: normalizeVolume) { _, _ in engine.reapplyNormalization() }
        .onChange(of: smartShuffle) { _, on in if !on { engine.queue.removeSmartRows() } }
        .onAppear {
            privateSession = PrivateSession.isActive
            hiddenCount  = SuggestionFeedback.hiddenSongs.count
            blockedCount = SuggestionFeedback.blockedArtists.count
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

/// A bindable speed. `Float` isn't `Identifiable`, and rounding to a label loses the selection.
struct PlaybackSpeed: Identifiable, Hashable {
    let value: Double
    var id: Double { value }
    var title: String { value == 1.0 ? "Normal" : String(format: "%g×", value) }
}

// MARK: - Downloads

struct DownloadsPane: View {

    @ObservedObject var manager: DownloadManager
    @EnvironmentObject private var exportManager: ExportManager
    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var prefetch = PlaybackPrefetchSettings.shared
    @State private var confirmRequality = false
    @State private var confirmResave = false

    private var editCount: Int { deps.libraryService.tracks.lazy.filter { $0.origin == .edit }.count }
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

                // Wi-Fi Only blocks metered downloads outright, so there'd be nothing for this to lower.
                if !manager.downloadOnWifiOnly {
                    SettingsToggleRow(id: "downloads.autoAdjust",
                                      title: "Lower Quality on Mobile Data",
                                      subtitle: "Downloads drop one step below the quality above when you're off Wi-Fi.",
                                      icon: "antenna.radiowaves.left.and.right",
                                      isOn: Binding(get: { manager.autoAdjustQuality },
                                                    set: { manager.autoAdjustQuality = $0 }))
                }

                // Songs on disk keep the quality they were written at.
                if manager.offlineCount > 0 {
                    SettingsButtonRow(id: "downloads.redownload",
                                      title: "Re-download at This Quality",
                                      icon: "arrow.triangle.2.circlepath") {
                        confirmRequality = true
                    }
                }

                SettingsPickerRow(id: "downloads.editQuality",
                                  title: "Song Edit Quality",
                                  subtitle: "\(manager.editQuality.detail) Edits you've already saved keep theirs.",
                                  icon: "slider.horizontal.3",
                                  selection: Binding(get: { manager.editQuality },
                                                     set: { manager.editQuality = $0 }),
                                  options: EditQuality.allCases) { $0.title }

                if editCount > 0 {
                    SettingsButtonRow(id: "downloads.resaveEdits",
                                      title: "Re-save Edits at This Quality",
                                      icon: "arrow.triangle.2.circlepath") {
                        confirmResave = true
                    }
                }
            }

            SettingsGroup(title: "Automatic Downloads") {
                // "Imported" means file/folder import, Spotify transfer, or a saved/restored share,
                // not every playlist a sign-in pulls down. Same choice as the playlist page's download button.
                SettingsToggleRow(id: "downloads.autoImported",
                                  title: "Keep Imported Playlists Offline",
                                  subtitle: "Playlists you import or save are downloaded automatically, including songs added to them later.",
                                  icon: "arrow.down.circle",
                                  isOn: Binding(get: { manager.autoDownloadImportedPlaylists },
                                                set: { manager.autoDownloadImportedPlaylists = $0 }))
            }

            // These fill the playback cache, which is temporary, but they cost a download so they live here.
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
                                  // Ethernet counts: the setting is about mobile data. See `isUnmetered`.
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
        .alert("Re-save edits at \(manager.editQuality.title) quality?", isPresented: $confirmResave) {
            Button("Cancel", role: .cancel) {}
            Button("Re-save") { Task { await deps.resaveEdits() } }
        } message: {
            Text("Each edit is made again from the song it came from. Names, likes and playlists stay as they are.")
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
    /// The user-lyrics list takes the whole pane, like Connections' sub-pages.
    @State private var showUserLyrics = false
    @State private var showMergeDuplicates = false
    /// Index into `budgetStops`; a linear 256 MB-50 GB slider would waste most of its travel.
    @State private var budgetStop: Double = 0

    private static let budgetStops: [Int64] = {
        let gb = Int64(1_024 * 1_024 * 1_024)
        return [gb / 4, gb / 2, gb, 2 * gb, 4 * gb, 8 * gb, 16 * gb, 32 * gb, 50 * gb]
    }()

    private static func clampStop(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), budgetStops.count - 1)
    }

    /// The nearest stop to the stored value, which an older build may have written.
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

            // Everything below re-fetches on demand, unlike downloads.
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

            // Not a cache: typed text can't be re-fetched.
            if lyricsStore.count > 0 {
                SettingsGroup(title: "Your Lyrics",
                              footer: "Lyrics you added yourself, for songs the app couldn't find or got wrong. They're kept on this device and shown instead of any lyrics found online.") {
                    // Opens the list so a wrong one can be fixed.
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

            // Not a cache: this changes the user's library.
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
            // Apply a lower limit now, not after the next download.
            let pinned = PlaybackCache.pinnedURLs
            Task {
                await Task.detached(priority: .utility) { PlaybackCache.enforceBudget(pinned: pinned) }.value
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
    /// The Spotify library picker takes the whole pane. See SpotifyConnectionView.
    @State private var showSpotifyLibrary = false
    /// Same for the likes-push page. Two flags since they're never both up.
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
        // Arriving from "Import Spotify Library" elsewhere: open the picker. See SettingsRoute.
        .onAppear {
            guard route.request?.opensSpotifyLibrary == true else { return }
            showSpotifyLibrary = true
            route.consume()
        }
    }

    private var pane: some View {
        SettingsPage(title: "Connections") {
            // Spotify first: it's the connection most people are here for.
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
    /// iOS can't run yt-dlp, so Discover plays through a resolver server. Shows whether it's working.
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

            // Developer-only override, gated by the same role as Developer Tools. The bearer token
            // is never sent to a typed address (see RemoteResolverService).
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
            // Keep the spinner up long enough to read.
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
    // Subscribes Sparkle to the "beta" channel. UpdaterController reads the same key.
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
    @EnvironmentObject private var deps: AppDependencies
    @State private var recapError: String?

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
            SettingsGroup(title: "Recap",
                          footer: "Only on this device. Nothing is saved, so the real recap still arrives on the 1st.") {
                SettingsButtonRow(title: "Preview This Month's Recap",
                                  icon: "play.rectangle.fill") {
                    Task {
                        recapError = await deps.recap.previewThisMonth()
                            .map { "Needs \(RecapMath.minimumPlays) plays this month, you have \($0)." }
                    }
                }
                if let recapError { SettingsErrorRow(message: recapError) }
                SettingsButtonRow(title: "Demo Recap",
                                  icon: "sparkles.rectangle.stack.fill") {
                    deps.recap.demoRecap()
                }
            }
        }
    }
}

// MARK: - Danger Zone

/// Everything that loses something for good lives here, so no ordinary page has a red button.
/// Ordered by reach: this device, the library everywhere, the account. Account deletion
/// finishes on mixtaped.tech, next to the data export.
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

                // Only when there's something to clean; deleting a playlist already takes its orphans.
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
        .mixConfirmationDialog("Reset All Settings",
                            isPresented: $confirmResetSettings,
                            titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) {
                SettingsReset.restoreDefaults(deps: deps, theme: theme)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default, including appearance, playback, downloads, and the equalizer. Your music, playlists, downloaded songs, and Last.fm connection are left alone.")
        }
        .mixConfirmationDialog("Remove Your Lyrics",
                            isPresented: $confirmRemoveLyrics,
                            titleVisibility: .visible) {
            Button("Remove Lyrics", role: .destructive) { lyricsStore.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The lyrics you added for \(lyricsStore.count) song\(lyricsStore.count == 1 ? "" : "s") will be deleted. Those songs go back to whatever the app can find online, which for most of them is nothing.")
        }
        .mixConfirmationDialog("Reset Listening History",
                            isPresented: $vm.showResetStatsConfirm,
                            titleVisibility: .visible) {
            Button("Reset History", role: .destructive) { Task { await vm.resetListeningStats() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every play is forgotten: top artists, top songs and minutes all go back to zero, here and on your public profile. Your music, playlists and liked songs are untouched.")
        }
        .mixConfirmationDialog("Remove Leftover Songs",
                            isPresented: $vm.showCleanOrphansConfirm,
                            titleVisibility: .visible) {
            Button("Remove \(vm.orphanCount) Song\(vm.orphanCount == 1 ? "" : "s")", role: .destructive) {
                Task { await vm.cleanUpOrphanedSongs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These songs came from playlists you deleted and nothing else in your library holds them — they're in no playlist and not liked. Deleting a playlist takes them with it now; this clears the ones left over from before.")
        }
        .mixConfirmationDialog("Delete All Playlists",
                            isPresented: $vm.showDeletePlaylistsConfirm,
                            titleVisibility: .visible) {
            Button("Delete All Playlists", role: .destructive) { Task { await vm.deleteAllUserPlaylists() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your created playlists will be permanently deleted from every device. All Songs and Liked Songs will remain. Your music is unaffected.")
        }
        .mixConfirmationDialog("Delete All Music",
                            isPresented: $vm.showDeleteTracksConfirm,
                            titleVisibility: .visible) {
            Button("Delete All Music", role: .destructive) { Task { await vm.deleteAllTracks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All tracks, albums, and artists will be permanently deleted from every device. Your playlists will remain but be empty.")
        }
        .mixConfirmationDialog("Clear Everything",
                            isPresented: $vm.showClearLibraryConfirm,
                            titleVisibility: .visible) {
            Button("Clear Everything", role: .destructive) { Task { await vm.clearLibrary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all music, albums, artists, playlists, liked songs, files and listening history — from the server and every device — and empties your public profile. Your account itself stays.")
        }
        .mixConfirmationDialog("Sign Out Everywhere",
                            isPresented: $confirmSignOutEverywhere,
                            titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { Task { await vm.signOutEverywhere() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device and browser signed in as \(handle) is signed out, including this one. Your library is kept.")
        }
        .mixConfirmationDialog("Delete \(handle)?",
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
