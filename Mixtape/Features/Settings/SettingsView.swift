// SettingsView.swift
// Mixtape — Features/Settings

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct SettingsView: View {

    @StateObject private var vm: SettingsViewModel
    @EnvironmentObject private var exportManager: ExportManager
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var theme: ThemeManager
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var showFolderPicker = false

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

    // MARK: - Settings content (platform-aware wrapper)

    @ViewBuilder
    private var settingsContent: some View {
        let listView = ZStack {
            Color.mixBackground.ignoresSafeArea()
            List {
                profileSection
                accountSection
                appearanceSection
                syncSection
                exportSection
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
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.mixPrimary, Color.mixPrimaryDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 64, height: 64)
            .overlay(
                Text(String(user.displayName.prefix(1)).uppercased())
                    .font(.mixTitle)
                    .foregroundStyle(.white)
            )
            .shadow(color: Color.mixPrimary.opacity(0.35), radius: 10, y: 4)
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
            #if os(macOS)
            if vm.currentUser != nil {
                Button {
                    appState.showingAccount = true
                } label: {
                    settingsRow(
                        title: "Manage Account",
                        systemImage: "person.crop.circle",
                        tint: Color.mixPrimary,
                        titleColor: Color.mixTextPrimary,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.mixSurface)
            }
            #endif
            if vm.currentUser != nil {
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
            Text("Metadata and audio files sync automatically when online.")
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

#if os(macOS)

// MARK: - Account View (inline, full content area — Mixtape 1.1)
//
// Reached from Settings → "Manage Account". Rendered flat by MacContentRouter
// (like the album/playlist drill-downs) rather than as a sheet or new window.
// The Back button sets appState.showingAccount = false to return to Settings.

struct AccountView: View {

    @EnvironmentObject private var appState: MacAppState
    @ObservedObject var authService: SupabaseAuthService

    // Username
    @State private var username: String = ""
    @State private var usernameBusy = false
    @State private var usernameMessage: StatusMessage?

    // Email
    @State private var email: String = ""
    @State private var emailBusy = false
    @State private var emailMessage: StatusMessage?

    // Password
    @State private var currentPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var passwordBusy = false
    @State private var passwordMessage: StatusMessage?

    private struct StatusMessage: Equatable {
        let text: String
        let isError: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // Back bar — matches the album/playlist drill-down header.
            HStack {
                Button {
                    appState.showingAccount = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color.mixPrimary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.mixBackground)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Account")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .padding(.bottom, 2)

                    usernameCard
                    emailCard
                    passwordCard
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(Color.mixBackground)
        .onAppear { syncFieldsFromUser() }
    }

    // MARK: Username

    private var usernameCard: some View {
        card(title: "Username", footer: "Your username is visible to you and used to sign in.") {
            field("Username") {
                TextField("Username", text: $username)
                    .disableAutocorrection(true)
            }

            actionRow(
                title: "Save Username",
                busy: usernameBusy,
                disabled: trimmed(username).isEmpty
                    || trimmed(username).lowercased() == (authService.currentUser?.displayName.lowercased() ?? ""),
                message: usernameMessage
            ) {
                await saveUsername()
            }
        }
    }

    private func saveUsername() async {
        usernameBusy = true; usernameMessage = nil
        defer { usernameBusy = false }
        do {
            try await authService.updateUsername(trimmed(username))
            usernameMessage = StatusMessage(text: "Username updated.", isError: false)
        } catch {
            usernameMessage = StatusMessage(text: errorText(error), isError: true)
        }
    }

    // MARK: Email

    private var emailCard: some View {
        card(title: "Email", footer: "Changing your email sends a confirmation link to the new address. The change takes effect once you confirm.") {
            field("Email") {
                TextField("Email", text: $email)
                    .disableAutocorrection(true)
            }

            actionRow(
                title: "Update Email",
                busy: emailBusy,
                disabled: trimmed(email).isEmpty
                    || !trimmed(email).contains("@")
                    || trimmed(email).lowercased() == (authService.currentUser?.email.lowercased() ?? ""),
                message: emailMessage
            ) {
                await saveEmail()
            }
        }
    }

    private func saveEmail() async {
        emailBusy = true; emailMessage = nil
        defer { emailBusy = false }
        do {
            try await authService.updateEmail(trimmed(email))
            emailMessage = StatusMessage(text: "Confirmation link sent to \(trimmed(email)).", isError: false)
        } catch {
            emailMessage = StatusMessage(text: errorText(error), isError: true)
        }
    }

    // MARK: Password

    private var passwordCard: some View {
        card(title: "Password", footer: "Enter your current password, then choose a new one (at least 8 characters).") {
            field("Current password") {
                SecureField("Current password", text: $currentPassword)
            }
            field("New password") {
                SecureField("New password", text: $newPassword)
            }
            field("Confirm new password") {
                SecureField("Confirm new password", text: $confirmPassword)
            }

            actionRow(
                title: "Change Password",
                busy: passwordBusy,
                disabled: currentPassword.isEmpty
                    || newPassword.count < 8
                    || newPassword != confirmPassword,
                message: passwordMessage
            ) {
                await savePassword()
            }
        }
    }

    private func savePassword() async {
        passwordBusy = true; passwordMessage = nil
        defer { passwordBusy = false }
        do {
            try await authService.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            passwordMessage = StatusMessage(text: "Password changed.", isError: false)
            currentPassword = ""; newPassword = ""; confirmPassword = ""
        } catch {
            passwordMessage = StatusMessage(text: errorText(error), isError: true)
        }
    }

    // MARK: Card / row builders

    private func card<Content: View>(
        title: String,
        footer: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)

            content()

            Text(footer)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.mixSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.mixSeparator, lineWidth: 0.5)
                )
        )
    }

    /// A labelled, full-width input row. The field itself is large (44 pt tall,
    /// body-sized text) and styled to read like the rest of the app rather than
    /// a stock rounded-border control.
    private func field<F: View>(
        _ label: String,
        @ViewBuilder _ content: () -> F
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.mixCaptionBold)
                .tracking(0.5)
                .foregroundStyle(Color.mixTextSecondary)

            content()
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.mixBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.mixSeparator, lineWidth: 1)
                        )
                )
        }
    }

    private func actionRow(
        title: String,
        busy: Bool,
        disabled: Bool,
        message: StatusMessage?,
        action: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await action() }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(title).font(.mixButton)
                }
                .frame(minWidth: 130)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.mixPrimary)
            .disabled(disabled || busy)

            if let message {
                Text(message.text)
                    .font(.mixCaption)
                    .foregroundStyle(message.isError ? Color.mixDestructive : Color.mixSyncSynced)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Helpers

    private func syncFieldsFromUser() {
        if let user = authService.currentUser {
            if username.isEmpty { username = user.displayName }
            if email.isEmpty    { email = user.email }
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func errorText(_ error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }
}

#endif
