// Spotify as a connection, next to Last.fm: an account you link once and import from.
// Shows whose account it is and how to unlink. The picker opens in the settings pane,
// not a window or a sheet over a sheet.

import SwiftUI

// MARK: - Rows

/// What a profile load is keyed on: connected, and whether one is already held.
private struct ProfileLoadKey: Equatable {
    let isAuthorized: Bool
    let hasProfile: Bool
    /// Retries the load when Spotify stops throttling.
    let throttled: Bool
}

/// The Spotify block in Connections. `openLibrary` asks the pane to swap in `SpotifyLibraryPage`.
struct SpotifyConnectionGroup: View {

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject var auth: SpotifyAuth
    let openLibrary: () -> Void
    let openLikesPush: () -> Void

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showLinkImport = false
    @State private var confirmDisconnect = false
    @State private var historyBusy = false
    @State private var historyError: String?
    @ObservedObject private var throttle = SpotifyThrottle.shared

    var body: some View {
        SettingsGroup(title: "Spotify",
                      footer: auth.isAuthorized
                        ? "Mixtape only ever reads from Spotify — it never changes anything in your Spotify account."
                        : "Connect to bring your playlists, saved songs and albums across. Read access only.") {
            if auth.isAuthorized {
                SpotifyAccountRow(profile: auth.profile,
                                  throttled: throttle.isThrottled)

                // First row: while throttled, import and sync fail quietly.
                if let sentence = throttle.sentence {
                    SettingsErrorRow(message: sentence)
                }

                if auth.needsReauthorization {
                    SettingsButtonRow(title: "Reconnect for Saved Songs & Albums",
                                      subtitle: "This connection predates Mixtape asking for them, so only playlists are listed.",
                                      icon: "exclamationmark.arrow.triangle.2.circlepath",
                                      isEnabled: !isConnecting) {
                        connect()
                    } trailing: {
                        if isConnecting { ProgressView().controlSize(.small) }
                    }
                }

                SettingsButtonRow(id: "connections.spotifyLibrary",
                                  title: "Import Library\u{2026}",
                                  subtitle: "Choose playlists, saved songs and albums to bring across.",
                                  icon: "square.and.arrow.down.on.square",
                                  role: .plain,
                                  showsChevron: true,
                                  action: openLibrary)

                SettingsButtonRow(id: "connections.spotifyLink",
                                  title: "Import a Playlist Link\u{2026}",
                                  subtitle: "For one playlist, pasted from Share \u{2192} Copy link.",
                                  icon: "link",
                                  role: .plain) {
                    showLinkImport = true
                }

                SpotifyLikesPushRow(auth: auth, onOpen: openLikesPush)

                SettingsToggleRow(id: "connections.spotifyHistory",
                                  title: "Add Spotify Listening to Recaps",
                                  subtitle: "Checks what you've played on Spotify every half hour, even while Mixtape is closed.",
                                  icon: "clock.arrow.circlepath",
                                  isOn: Binding(get: { auth.historySync }, set: setHistorySync),
                                  isEnabled: !historyBusy)

                if let historyError {
                    SettingsErrorRow(message: historyError)
                }

                SettingsButtonRow(id: "connections.spotifyDisconnect",
                                  title: "Disconnect",
                                  icon: "xmark.circle",
                                  role: .destructive) {
                    confirmDisconnect = true
                }
            } else {
                SettingsButtonRow(id: "connections.spotify",
                                  title: "Connect Spotify",
                                  subtitle: "Sign in to Spotify to list your library here.",
                                  icon: "personalhotspot",
                                  isEnabled: !isConnecting) {
                    connect()
                } trailing: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingsValue(text: "Not connected", color: .mixTextTertiary)
                    }
                }

                if let connectError {
                    SettingsErrorRow(message: connectError)
                }
            }
        }
        // Keyed on having a profile too: re-consenting clears the cached account and has to refetch it.
        .task(id: ProfileLoadKey(isAuthorized: auth.isAuthorized,
                                 hasProfile: auth.profile != nil,
                                 throttled: throttle.isThrottled)) {
            auth.loadProfile(using: deps.spotifyClient)
        }
        .sheet(isPresented: $showLinkImport) {
            SpotifyImportView(spotifyClient: deps.spotifyClient,
                              importService: deps.spotifyImportService,
                              auth: deps.spotifyAuth,
                              followService: deps.spotifyFollowService,
                              ledger: deps.spotifyImportLedger)
                .environmentObject(deps)
        }
        .alert("Disconnect Spotify?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) { auth.disconnect() }
        } message: {
            Text("Everything you've already imported stays in your library. You'll need to sign in again to import anything else.")
        }
    }

    private func setHistorySync(_ on: Bool) {
        historyError = nil
        historyBusy = true
        Task {
            do {
                try await auth.setHistorySync(on)
            } catch SpotifyAuthError.cancelled {
            } catch let error as SpotifyAuthError {
                historyError = error.errorDescription
            } catch {
                historyError = "Couldn't save that. Please try again."
            }
            historyBusy = false
        }
    }

    private func connect() {
        connectError = nil
        isConnecting = true
        Task {
            do {
                try await auth.connect()
                auth.loadProfile(using: deps.spotifyClient, force: true)
            } catch let error as SpotifyAuthError {
                connectError = error.errorDescription
            } catch {
                connectError = "Couldn't connect to Spotify. Please try again."
            }
            isConnecting = false
        }
    }
}

/// Who the connection belongs to: avatar, name and account details. First row in the card.
private struct SpotifyAccountRow: View {

    let profile: SpotifyProfile?
    /// Spotify is refusing us, which is why the name never arrived.
    var throttled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text(profile?.displayName ?? "Connected")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .lineLimit(1)
                } else {
                    // No second "Connected"; if the name isn't coming, don't show a spinner either.
                    Text(throttled
                         ? "Spotify is rate-limiting, can't read your account"
                         : "Reading your account\u{2026}")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer(minLength: 8)

            if let plan = profile?.planLabel {
                Text(plan)
                    .font(.mixCaptionBold)
                    .foregroundStyle(Self.spotifyGreen)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Self.spotifyGreen.opacity(0.16)))
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.spotifyGreen)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowPadH)
        .padding(.vertical, SettingsMetrics.rowPadV + 3)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }

    /// "@username · 1,240 followers", dropping missing halves. The id tells two accounts apart.
    private var detail: String? {
        guard let profile else { return nil }
        var parts: [String] = []
        if profile.displayName != profile.id { parts.append("@\(profile.id)") }
        if let followers = profile.followerCount, followers > 0 {
            parts.append("\(followers.formatted()) follower\(followers == 1 ? "" : "s")")
        }
        if let country = profile.country { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let url = profile?.imageURL {
                CachedRemoteImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Self.spotifyGreen.opacity(0.5), lineWidth: 1))
    }

    private var avatarFallback: some View {
        Self.spotifyGreen.opacity(0.18)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.spotifyGreen)
            )
    }

    /// Spotify's brand green, not the app palette.
    static let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)
}

// MARK: - Library page
// The picker, in the settings pane. Same model and rows as the sheet in Features/Import.

struct SpotifyLibraryPage: View {

    @StateObject private var model: SpotifyLibraryPickerModel
    @ObservedObject private var auth: SpotifyAuth
    let onBack: () -> Void

    @State private var confirmLeaveDuringImport = false
    /// Whether the pending confirmation came from Back (leave too) or Stop (stay).
    @State private var leaveAfterStopping = false

    init(spotifyClient: SpotifyClient,
         importService: SpotifyImportService,
         auth: SpotifyAuth,
         followService: SpotifyFollowService? = nil,
         ledger: SpotifyImportLedger? = nil,
         onBack: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SpotifyLibraryPickerModel(
            spotifyClient: spotifyClient,
            importService: importService,
            auth: auth,
            followService: followService,
            ledger: ledger
        ))
        self.auth = auth
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 0.5)

            body(for: model.phase)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mixBackground)
        .task(id: auth.isAuthorized) {
            await model.loadIfNeeded()
        }
        .onDisappear {
            // Leaving stops the run, like closing the sheet.
            model.cancelMigration()
        }
        .mixConfirmationDialog(
            "Stop importing?",
            isPresented: $confirmLeaveDuringImport,
            titleVisibility: .visible
        ) {
            Button("Stop and Remove", role: .destructive) {
                model.cancelMigration()
                if leaveAfterStopping { onBack() }
            }
            Button("Keep Importing", role: .cancel) { }
        } message: {
            Text(leaveDuringImportMessage)
        }
    }

    /// Stopping undoes the run, so the warning says so up front.
    private var leaveDuringImportMessage: String {
        guard let progress = model.progress, progress.overallCompleted > 0 else {
            return "Nothing has been imported yet. You can start again any time."
        }
        let songs = progress.overallCompleted == 1
            ? "1 song"
            : "\(progress.overallCompleted) songs"
        return "The \(songs) imported so far will be removed from your library. Songs you already had are kept."
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                // Mid-run, Back is destructive, so ask first.
                if model.phase == .migrating {
                    leaveAfterStopping = true
                    confirmLeaveDuringImport = true
                } else {
                    onBack()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Connections")
                        .font(.mixLabel)
                }
                .foregroundStyle(Color.mixTextSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            // Enabled during a run: leaving stops the import (`onDisappear`), and the help says so.
            .help(model.phase == .migrating
                  ? "Go back \u{2014} asks before stopping and undoing the import"
                  : "Back to Connections")

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from Spotify")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        // Bounded: an unbounded `fixedSize` in the narrow settings column balloons the window height.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                actions
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        switch model.phase {
        case .migrating:
            return "Bringing your music across. You can keep using Mixtape while this runs."
        case .finished where model.result?.wasCancelled == true:
            return "The import was stopped and undone. Your library is as it was."
        case .finished:
            return "Everything that came across is in your library now."
        default:
            return "Pick what to bring over. Songs already in your library are reused, not duplicated."
        }
    }

    @ViewBuilder
    private func body(for phase: SpotifyLibraryPickerModel.Phase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if auth.isAuthorized, auth.needsReauthorization {
                MixSheetStatus(
                    kind: .failure,
                    title: "Reconnect to see everything",
                    detail: "Your Spotify connection predates Mixtape asking for Liked Songs and saved albums, so only playlists are listed. Reconnecting takes one tap and only adds read access."
                )
            }

            if phase == .choosing {
                SpotifyLibraryChooser(model: model)
            } else {
                SpotifyLibraryStatus(model: model, isAuthorized: auth.isAuthorized)
                Spacer(minLength: 0)
            }
        }
    }

    /// One button beside the title: connect, then import, then done.
    private var actions: some View {
        HStack(spacing: 10) {
            // Reconnect is offered beside Import, not instead: an old grant still lists playlists.
            if auth.isAuthorized, auth.needsReauthorization, model.phase != .migrating {
                Button("Reconnect") { model.connect() }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .disabled(model.isConnecting)
            }

            primaryButton
        }
        // Horizontal only, so the row can't grow taller than one line.
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if !auth.isAuthorized {
            actionButton("Connect Spotify", isBusy: model.isConnecting) { model.connect() }
        } else {
            switch model.phase {
            case .idle, .loading:
                actionButton("Import", isEnabled: false, isBusy: model.phase == .loading) { }
            case .failed:
                actionButton("Try Again") { Task { await model.load() } }
            case .choosing:
                let songs = model.selectedNewSongCount
                actionButton(model.selection.isEmpty || songs == 0
                                ? "Import"
                                : "Import \(songs) Song\(songs == 1 ? "" : "s")",
                             isEnabled: !model.selection.isEmpty) {
                    model.startMigration()
                }
            case .migrating:
                actionButton("Stop", isDestructive: true) {
                    leaveAfterStopping = false
                    confirmLeaveDuringImport = true
                }
            case .finished:
                HStack(spacing: 10) {
                    Button("Import More") { model.startOver() }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                    actionButton("Done", action: onBack)
                }
            }
        }
    }

    private func actionButton(_ title: String,
                              isEnabled: Bool = true,
                              isBusy: Bool = false,
                              isDestructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .font(.mixBodyBold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isDestructive ? Color.mixDestructive : Color.mixPrimary)
            )
            .opacity(isEnabled && !isBusy ? 1 : 0.55)
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled || isBusy)
    }
}
