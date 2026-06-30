// SettingsView.swift
// Mixtape — Features/Settings

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct SettingsView: View {

    @StateObject private var vm: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var exportManager: ExportManager
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var theme: ThemeManager
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @AppStorage(ProfileStatsService.sharingDefaultsKey) private var shareListeningActivity = true
    @State private var showFolderPicker = false
    @State private var showEqualizer = false
    @State private var showAccount = false
    @State private var showFindPeople = false
    @State private var showLastFm = false
    @State private var discoverCacheCleared = false
    @State private var playedTracksReset = false
    @ObservedObject private var scrobbler = LastFmScrobbler.shared
    #if os(iOS)
    // Resolver server (Mac-as-server / hosted) that turns Discover tracks into
    // playable audio for iOS. Stored under the same key RemoteResolverService reads.
    @AppStorage(RemoteResolverService.baseURLDefaultsKey) private var resolverURLString = ""
    @State private var resolverTesting = false
    @State private var resolverTestResult: ResolverTestResult? = nil
    @State private var showResolverAdvanced = false
    @EnvironmentObject private var resolverStatus: ResolverStatusService
    #endif

    public init(
        authService:    SupabaseAuthService,
        syncService:    SupabaseSyncService,
        libraryService: LibraryService,
        importService:  ImportService
    ) {
        _vm = StateObject(wrappedValue: SettingsViewModel(
            authService:    authService,
            syncService:    syncService,
            libraryService: libraryService,
            importService:  importService
        ))
    }

    public var body: some View {
        settingsContent
            #if os(iOS)
            .sheet(isPresented: $showEqualizer) {
                NavigationStack {
                    ScrollView {
                        EqualizerView(equalizer: deps.equalizer)
                    }
                    .background(Color.mixBackground.ignoresSafeArea())
                    .navigationTitle("Equalizer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showEqualizer = false }
                                .foregroundStyle(Color.mixPrimary)
                        }
                    }
                }
            }
            #endif
            // Manage Account — presented from the account section on both platforms.
            .sheet(isPresented: $showAccount) {
                accountSheet
            }
            .sheet(isPresented: $showFindPeople) {
                FindPeopleView(authService: deps.authService)
            }
            .sheet(isPresented: $showLastFm) {
                LastFmConnectView()
            }
            // Sign out
            .confirmationDialog(
                "Sign Out",
                isPresented: $vm.showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await vm.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign in again to access your synced library.")
            }
            // Delete all tracks
            .confirmationDialog(
                "Delete All Music",
                isPresented: $vm.showDeleteTracksConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All Music", role: .destructive) {
                    Task { await vm.deleteAllTracks() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All tracks, albums, and artists will be permanently deleted from every device. Your playlists will remain but be empty.")
            }
            // Delete all user playlists
            .confirmationDialog(
                "Delete All Playlists",
                isPresented: $vm.showDeletePlaylistsConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All Playlists", role: .destructive) {
                    Task { await vm.deleteAllUserPlaylists() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All your created playlists will be permanently deleted from every device. All Songs and Favourites will remain. Your music is unaffected.")
            }
            // Clear entire database
            .confirmationDialog(
                "Clear Entire Database",
                isPresented: $vm.showClearLibraryConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Everything", role: .destructive) {
                    Task { await vm.clearLibrary() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all music, playlists, and files from the server and every device. This cannot be undone.")
            }
    }

    // MARK: - Manage Account sheet (shared chrome, platform-specific toolbar)

    @ViewBuilder
    private var accountSheet: some View {
        #if os(iOS)
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
        #else
        VStack(spacing: 0) {
            HStack {
                Text("Account")
                    .font(.mixTitle2)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                Button("Done") { showAccount = false }
                    .foregroundStyle(Color.mixPrimary)
            }
            .padding(16)

            Divider().background(Color.mixSeparator)

            AccountSettingsView()
        }
        .frame(minWidth: 460, minHeight: 480)
        .background(Color.mixBackground)
        #endif
    }

    // MARK: - Settings content (platform-aware wrapper)

    @ViewBuilder
    private var settingsContent: some View {
        let listView = ZStack {
            Color.mixBackground.ignoresSafeArea()
            List {
                profileSection
                accountSection
                appearanceSection
                playbackSection
                syncSection
                lastFmSection
                exportSection
                #if os(iOS)
                resolverSection
                #endif
                discoverCacheSection
                if vm.isDeveloper {
                    librarySection
                }
                aboutSection
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .tint(Color.mixPrimary)
        }
        .navigationTitle("Settings")

        #if os(iOS)
        NavigationStack { listView
                .navigationBarTitleDisplayMode(.large)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .tint(Color.mixPrimary)
                    }
                }
        }
        #else
        listView
        #endif
    }

    // MARK: - Sections

    /// Prominent profile header card at the very top of the list.
    private var profileSection: some View {
        Section {
            if let user = vm.currentUser {
                HStack(spacing: 16) {
                    avatar(for: user)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.displayName)
                            .font(.mixTitle2)
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        Text(user.email)
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(profileCardBackground)
            }
        }
    }

    private func avatar(for user: AppUser) -> some View {
        AvatarView(url: user.avatarURL, fallbackText: user.displayName, size: 64)
    }

    private var profileCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.mixSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.mixSeparator, lineWidth: 0.5)
            )
    }

    private var accountSection: some View {
        Section {
            if vm.currentUser != nil {
                // Manage Account — presents the auth team's AccountSettingsView.
                Button {
                    showFindPeople = true
                } label: {
                    settingsRow(
                        title: "Find People",
                        systemImage: "person.2.fill",
                        showsChevron: true
                    )
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)

                Button {
                    showAccount = true
                } label: {
                    settingsRow(
                        title: "Manage Account",
                        systemImage: "person.crop.circle",
                        showsChevron: true
                    )
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)

                Toggle(isOn: $shareListeningActivity) {
                    rowLabel(title: "Show my listening activity", systemImage: "waveform", tint: .mixPrimary, titleColor: .mixTextPrimary)
                }
                .tint(Color.mixPrimary)
                .listRowBackground(Color.mixSurface)
                .onChange(of: shareListeningActivity) { _, newValue in
                    if let id = deps.authService.currentUser?.id {
                        Task { await deps.profileStatsService.setSharing(newValue, userID: id) }
                    }
                }

                Button(role: .destructive) {
                    vm.showSignOutConfirm = true
                } label: {
                    settingsRow(
                        title: "Sign Out",
                        systemImage: MixtapeIcons.signOut,
                        tint: Color.mixDestructive
                    )
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)
            }
        } header: {
            SectionHeader("Account")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: $theme.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            } label: {
                rowLabel(title: "Appearance", systemImage: "circle.lefthalf.filled", tint: .mixPrimary, titleColor: .mixTextPrimary)
            }
            .listRowBackground(Color.mixSurface)

            #if os(iOS)
            Toggle(isOn: $hapticsEnabled) {
                rowLabel(title: "Haptic feedback", systemImage: "hand.tap.fill", tint: .mixPrimary, titleColor: .mixTextPrimary)
            }
            .tint(Color.mixPrimary)
            .listRowBackground(Color.mixSurface)
            #endif
        } header: {
            SectionHeader("Appearance")
        }
    }

    private var playbackSection: some View {
        Section {
            #if os(macOS)
            // Inline EQ on macOS Preferences — it fits the wider layout.
            EqualizerView(equalizer: deps.equalizer)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.mixBackground)
            #else
            Button {
                showEqualizer = true
            } label: {
                settingsRow(
                    title: "Equalizer",
                    systemImage: "slider.vertical.3",
                    showsChevron: true,
                    trailingText: deps.equalizer.isEnabled ? deps.equalizer.preset.rawValue : "Off"
                )
            }
            .listRowBackground(Color.mixSurface)
            #endif

            Picker(selection: Binding(
                get: { deps.playbackEngine.crossfadeMode },
                set: { deps.playbackEngine.setCrossfadeMode($0) }
            )) {
                ForEach(CrossfadeMode.allCases) { Text($0.title).tag($0) }
            } label: {
                rowLabel(title: "Crossfade", systemImage: "wand.and.rays")
            }
            .listRowBackground(Color.mixSurface)

            if deps.playbackEngine.crossfadeMode == .crossfade {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        rowLabel(title: "Crossfade length", systemImage: "timer")
                        Spacer()
                        Text("\(Int(deps.playbackEngine.crossfadeDuration))s")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                    Slider(
                        value: Binding(
                            get: { deps.playbackEngine.crossfadeDuration },
                            set: { deps.playbackEngine.setCrossfadeDuration($0) }
                        ),
                        in: 2...12, step: 1
                    )
                    .tint(Color.mixPrimary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.mixSurface)
            }
        } header: {
            SectionHeader("Playback")
        }
    }

    private var lastFmSection: some View {
        Section {
            Button {
                showLastFm = true
            } label: {
                settingsRow(
                    title: "Account",
                    systemImage: "waveform",
                    showsChevron: true,
                    trailingText: scrobbler.isConfigured
                        ? (scrobbler.username ?? "Connected")
                        : "Not connected"
                )
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .listRowBackground(Color.mixSurface)

            settingsRow(title: "Scrobble what I play", systemImage: "dot.radiowaves.left.and.right") {
                Toggle("", isOn: $scrobbler.isEnabled)
                    .labelsHidden()
                    .tint(Color.mixPrimary)
                    .disabled(!scrobbler.isConfigured)
            }
            .listRowBackground(Color.mixSurface)
        } header: {
            SectionHeader("Last.fm")
        } footer: {
            Text("Scrobble your listens to Last.fm. Tap Account to connect with your own API key.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private var syncSection: some View {
        Section {
            settingsRow(title: "Sync Status", systemImage: MixtapeIcons.sync) {
                syncStatusBadge
            }
            .listRowBackground(Color.mixSurface)

            Button {
                Task { await vm.triggerSync() }
            } label: {
                settingsRow(
                    title: "Sync Now",
                    systemImage: MixtapeIcons.syncing,
                    tint: Color.mixPrimary,
                    titleColor: Color.mixPrimary
                )
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .listRowBackground(Color.mixSurface)

        } header: {
            SectionHeader("Sync")
        } footer: {
            Text("Metadata and audio files sync automatically when online. Supabase backend — M5.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private var exportSection: some View {
        Section {
            settingsRow(title: "Export Location", systemImage: "folder") {
                if let path = exportManager.exportURLDisplayPath {
                    Text(path)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not Set")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .listRowBackground(Color.mixSurface)

            Button {
                #if os(macOS)
                FolderPickerHelper.show { url in
                    if let url = url {
                        try? exportManager.setExportURL(url)
                    }
                }
                #else
                showFolderPicker = true
                #endif
            } label: {
                #if os(macOS)
                settingsRow(title: "Change Location", systemImage: "arrow.down.circle", tint: Color.mixPrimary, titleColor: Color.mixPrimary)
                #else
                settingsRow(title: "Change Download Location", systemImage: "arrow.down.circle", tint: Color.mixPrimary, titleColor: Color.mixPrimary)
                #endif
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .listRowBackground(Color.mixSurface)

            #if os(macOS)
            if exportManager.exportURL != nil {
                Button {
                    if let url = exportManager.exportURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    settingsRow(title: "Open Folder", systemImage: "arrow.up.right.square", tint: Color.mixPrimary, titleColor: Color.mixPrimary)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.mixSurface)
            }
            #endif

            Toggle(isOn: Binding(
                get: { deps.downloadManager.downloadOnWifiOnly },
                set: { deps.downloadManager.downloadOnWifiOnly = $0 }
            )) {
                rowLabel(title: "Download on Wi-Fi Only", systemImage: "wifi")
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.mixPrimary))
            .listRowBackground(Color.mixSurface)

            Toggle(isOn: Binding(
                get: { deps.downloadManager.syncMetadataToDisk },
                set: { deps.downloadManager.syncMetadataToDisk = $0 }
            )) {
                rowLabel(title: "Update Files on Disk when Metadata Changes", systemImage: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.mixPrimary))
            .listRowBackground(Color.mixSurface)
        } header: {
            SectionHeader("Downloads")
        } footer: {
            Text("Choose where exported audio files are saved when you tap Download to Disk.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
        .sheet(isPresented: $showFolderPicker) {
            #if os(iOS)
            IOSFolderPicker { url in
                if let url = url {
                    try? exportManager.setExportURL(url)
                }
            }
            #endif
        }
    }

    #if os(iOS)
    /// iOS-only: configure the resolver server address used to stream Discover
    /// tracks (iOS can't run yt-dlp, so it asks a Mac/hosted server for the audio).
    private var resolverSection: some View {
        Section {
            // Live status: is streaming reachable?
            HStack(spacing: 12) {
                rowLabel(title: resolverStatusTitle,
                         systemImage: "antenna.radiowaves.left.and.right",
                         tint: resolverStatusColor)
                Spacer(minLength: 8)
                if resolverStatus.status == .checking {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Circle()
                        .fill(resolverStatusColor)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.mixSurface)

            // Test button with explicit, lingering pass/fail feedback.
            Button {
                runResolverTest()
            } label: {
                HStack(spacing: 12) {
                    rowLabel(title: resolverTesting ? "Testing…" : "Test Connection",
                             systemImage: "bolt.horizontal.circle")
                    Spacer(minLength: 8)
                    if resolverTesting {
                        ProgressView().scaleEffect(0.8)
                    } else if let result = resolverTestResult {
                        Image(systemName: result.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(result.tint)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .disabled(resolverTesting)
            .listRowBackground(Color.mixSurface)

            if !resolverTesting, let result = resolverTestResult {
                Text(result.message)
                    .font(.mixCaption)
                    .foregroundStyle(result.tint)
                    .listRowBackground(Color.mixSurface)
            }

            // Developer-only manual override, gated by Supabase role (same gate
            // as Developer Tools). Hidden from everyone else, and the bearer
            // token is never sent to a typed address (see RemoteResolverService).
            if vm.isDeveloper {
                DisclosureGroup(isExpanded: $showResolverAdvanced) {
                    HStack(spacing: 12) {
                        Text("Resolver")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                        Spacer(minLength: 8)
                        TextField("Default (hosted)", text: $resolverURLString)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextSecondary)
                            .onChange(of: resolverURLString) { _, _ in
                                Task { await resolverStatus.refresh() }
                            }
                    }
                    .padding(.vertical, 4)
                } label: {
                    rowLabel(title: "Advanced", systemImage: "slider.horizontal.3")
                }
                .tint(Color.mixTextSecondary)
                .listRowBackground(Color.mixSurface)
            }
        } header: {
            SectionHeader("Streaming")
        } footer: {
            Text("Discover streams automatically — no setup needed.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
        .task { await resolverStatus.refresh() }
    }

    private func runResolverTest() {
        resolverTesting = true
        resolverTestResult = nil
        Task {
            // Ensure the spinner is visible long enough to read even when the
            // health check returns near-instantly.
            async let probe = resolverStatus.refresh()
            try? await Task.sleep(for: .milliseconds(450))
            let source = await probe
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                resolverTesting = false
                resolverTestResult = source != nil
                    ? .success("Connected — streaming is working.")
                    : .failure("Couldn’t connect. Check your internet and try again.")
            }
            // Auto-clear so the row returns to its resting state.
            try? await Task.sleep(for: .seconds(5))
            if !resolverTesting {
                withAnimation { resolverTestResult = nil }
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
        case .offline:  return "Not connected"
        }
    }

    private var resolverStatusColor: Color {
        switch resolverStatus.status {
        case .checking: return .mixTextSecondary
        case .online:   return .mixPrimary
        case .offline:  return .mixDestructive
        }
    }
    #endif

    private var discoverCacheSection: some View {
        Section {
            Button {
                let spotify = deps.spotifyClient
                Task {
                    await spotify.clearImageCache()
                    await MainActor.run { LyricsService.shared.clearCache() }
                    URLCache.shared.removeAllCachedResponses()
                    await MainActor.run { discoverCacheCleared = true }
                }
            } label: {
                settingsRow(
                    title: discoverCacheCleared ? "Discover Cache Cleared" : "Clear Discover Cache",
                    systemImage: discoverCacheCleared ? "checkmark.circle" : "trash",
                    tint: Color.mixPrimary,
                    titleColor: Color.mixPrimary
                )
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .listRowBackground(Color.mixSurface)

            Button(role: .destructive) {
                let coordinator = deps.onlineCoordinator
                Task {
                    coordinator.clearCache()
                    await MainActor.run { playedTracksReset = true }
                }
            } label: {
                settingsRow(
                    title: playedTracksReset ? "Played Tracks Reset" : "Reset Played Tracks",
                    systemImage: playedTracksReset ? "checkmark.circle" : "arrow.counterclockwise",
                    tint: playedTracksReset ? Color.mixPrimary : Color.mixDestructive,
                    titleColor: playedTracksReset ? Color.mixPrimary : Color.mixDestructive
                )
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .listRowBackground(Color.mixSurface)
        } header: {
            SectionHeader("Discover")
        } footer: {
            Text("Clear Discover Cache clears cached artist photos and lyrics so they refetch fresh. Reset Played Tracks deletes every downloaded song so they re-download next time you play them — use this to pick up the new explicit (uncensored) versions.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private var syncStatusBadge: some View {
        Group {
            switch vm.syncState {
            case .idle:
                Text("Idle")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            case .syncing:
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7)
                    Text("Syncing")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixSyncPending)
                }
            case .upToDate(let date):
                Text("Up to date · \(date.formatted(.relative(presentation: .named)))")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixSyncSynced)
            case .pendingChanges(let count):
                Text("\(count) pending")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixSyncPending)
            case .error(let msg):
                Text("Error: \(msg)")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixSyncConflict)
                    .lineLimit(1)
            }
        }
    }

    private var librarySection: some View {
        Section {
            // ── Rebuild Groupings ─────────────────────────────────────────────
            if vm.isRebuilding {
                busyRow("Rebuilding artist & album groupings…")
            } else {
                Button {
                    Task { await vm.rebuildGroupings() }
                } label: {
                    settingsRow(title: "Rebuild Library Groupings", systemImage: "arrow.triangle.2.circlepath", tint: Color.mixPrimary, titleColor: Color.mixPrimary)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)
            }

            // ── Delete All Music ──────────────────────────────────────────────
            if vm.isDeletingTracks {
                busyRow("Deleting music from server…")
            } else {
                Button(role: .destructive) {
                    vm.showDeleteTracksConfirm = true
                } label: {
                    settingsRow(title: "Delete All Music", systemImage: "music.note.slash", tint: Color.mixDestructive)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)
            }
            if let err = vm.deleteTracksError {
                errorRow(err)
            }

            // ── Delete All Playlists ──────────────────────────────────────────
            if vm.isDeletingPlaylists {
                busyRow("Deleting playlists from server…")
            } else {
                Button(role: .destructive) {
                    vm.showDeletePlaylistsConfirm = true
                } label: {
                    settingsRow(title: "Delete All Playlists", systemImage: "music.note.list", tint: Color.mixDestructive)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)
            }
            if let err = vm.deletePlaylistsError {
                errorRow(err)
            }

            // ── Clear Entire Database ─────────────────────────────────────────
            if vm.isClearing {
                busyRow("Clearing entire database…")
            } else {
                Button(role: .destructive) {
                    vm.showClearLibraryConfirm = true
                } label: {
                    settingsRow(title: "Clear Everything", systemImage: MixtapeIcons.delete, tint: Color.mixDestructive)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .listRowBackground(Color.mixSurface)
            }
            if let err = vm.clearError {
                errorRow(err)
            }

        } header: {
            SectionHeader("Developer Tools")
        } footer: {
            Text("These actions are immediate and affect all devices. Use with caution.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private func busyRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.mixPrimary)
            Text(label)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .listRowBackground(Color.mixSurface)
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.mixCaption)
            .foregroundStyle(Color.mixDestructive)
            .listRowBackground(Color.mixSurface)
    }

    private var aboutSection: some View {
        Section {
            settingsRow(title: "Version", systemImage: "info.circle") {
                Text(appVersion)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .listRowBackground(Color.mixSurface)

            settingsRow(title: "Build", systemImage: "hammer") {
                Text(buildNumber)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .listRowBackground(Color.mixSurface)
        } header: {
            SectionHeader("About")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Row builders

    /// A leading icon + title label with a consistent accent-tinted icon chip.
    private func rowLabel(
        title: String,
        systemImage: String,
        tint: Color = .mixPrimary,
        titleColor: Color = .mixTextPrimary
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.15))
                )
            Text(title)
                .font(.mixBody)
                .foregroundStyle(titleColor)
        }
    }

    /// A full settings row: leading icon + title, optional trailing content / text / chevron.
    private func settingsRow<Trailing: View>(
        title: String,
        systemImage: String,
        tint: Color = .mixPrimary,
        titleColor: Color = .mixTextPrimary,
        showsChevron: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            rowLabel(title: title, systemImage: systemImage, tint: tint, titleColor: titleColor)
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Overload for rows with only a trailing text value.
    private func settingsRow(
        title: String,
        systemImage: String,
        tint: Color = .mixPrimary,
        titleColor: Color = .mixTextPrimary,
        showsChevron: Bool = false,
        trailingText: String? = nil
    ) -> some View {
        settingsRow(
            title: title,
            systemImage: systemImage,
            tint: tint,
            titleColor: titleColor,
            showsChevron: showsChevron
        ) {
            if let trailingText {
                Text(trailingText)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
    }
}

#if os(iOS)
/// Result of a manual "Test Connection" tap in the Streaming section.
private enum ResolverTestResult {
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
        case .success: return .mixPrimary
        case .failure: return .mixDestructive
        }
    }
}
#endif

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .tracking(0.6)
            .textCase(nil)
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    return SettingsView(authService: deps.authService, syncService: deps.syncService, libraryService: deps.libraryService, importService: deps.importService)
        .environmentObject(deps)
}
