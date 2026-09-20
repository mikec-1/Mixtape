// SpotifyConnectionView.swift
// Mixtape — Features/Settings
//
// Spotify as a *connection*, next to Last.fm, rather than a menu item filed
// under "add music".
//
// Importing a Spotify library isn't one action, it's an account you link once
// and then draw from: the token lives in the keychain, it grants read access to
// somebody's playlists, and until now nothing in the app said whose account it
// was or offered a way to unlink it. That's a connection, and connections have a
// home. The import itself opens in place — the picker fills the settings pane
// instead of a window floating over the app, because a listing of forty
// playlists deserves the width and because a sheet over a sheet on iOS was
// always one layer too many.

import SwiftUI

// MARK: - Rows

/// What a profile load is keyed on: connected, and whether one is already held.
private struct ProfileLoadKey: Equatable {
    let isAuthorized: Bool
    let hasProfile: Bool
    /// So the load is tried again the moment Spotify starts answering; without
    /// it a card that failed under a rate limit stayed failed until the pane
    /// was left and reopened.
    let throttled: Bool
}

/// The Spotify block inside the Connections pane. `openLibrary` hands control
/// back to the pane, which swaps in `SpotifyLibraryPage` where its own content
/// was — the "in the window, not over it" part.
struct SpotifyConnectionGroup: View {

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject var auth: SpotifyAuth
    let openLibrary: () -> Void
    let openLikesPush: () -> Void

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showLinkImport = false
    @State private var confirmDisconnect = false
    @ObservedObject private var throttle = SpotifyThrottle.shared

    var body: some View {
        SettingsGroup(title: "Spotify",
                      footer: auth.isAuthorized
                        ? "Mixtape only ever reads from Spotify — it never changes anything in your Spotify account."
                        : "Connect to bring your playlists, saved songs and albums across. Read access only.") {
            if auth.isAuthorized {
                SpotifyAccountRow(profile: auth.profile,
                                  throttled: throttle.isThrottled)

                // First row in the card, above everything it stops working.
                // While this stands, importing and syncing fail — and the
                // failure is silent enough that people conclude Mixtape is
                // broken rather than that Spotify is busy.
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
        // Keyed on whether there *is* a profile, not just on being connected.
        // Re-consenting clears the cached account — a new grant can belong to a
        // different one — and with the id keyed on `isAuthorized` alone, which
        // never changed, nothing asked for the new one: the card sat on
        // "Reading your account…" until the pane was left and reopened.
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

/// Who the connection belongs to: avatar, name, and the details Spotify gives
/// us about the account. Deliberately the first row in the card — a linked
/// account should say whose it is before it says what it can do.
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
                    // The name is still on its way. Saying "Connected" twice
                    // would be worse than saying nothing — and when it is never
                    // coming, "Reading your account…" is a spinner that lies.
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

    /// "@username · 1,240 followers", dropping whichever halves Spotify didn't
    /// send. The id is worth showing on its own: display names aren't unique
    /// and someone with two accounts can only tell them apart by it.
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

    /// Spotify's own green. Hard-coded rather than taken from the palette
    /// because it identifies the service, not the app — the same reason the
    /// Last.fm row doesn't get to be orange.
    static let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)
}

// MARK: - Library page
//
// The picker, filling the settings pane. Same model and same rows as the sheet
// in Features/Import — only the frame around them differs.

struct SpotifyLibraryPage: View {

    @StateObject private var model: SpotifyLibraryPickerModel
    @ObservedObject private var auth: SpotifyAuth
    let onBack: () -> Void

    @State private var confirmLeaveDuringImport = false
    /// Whether the pending confirmation came from the back button (leave the
    /// page too) or from Stop (stay, and show the result).
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
            // Leaving the page stops the run, for the same reason closing the
            // sheet does: nothing should go on writing to a library with no
            // way on screen to stop it.
            model.cancelMigration()
        }
        .confirmationDialog(
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

    /// Says what stopping actually does now: undoes the run.
    ///
    /// Half an import is not a useful thing to be left holding — 600 songs out
    /// of 2,200 is 600 songs you have to find and delete by hand — so stopping
    /// takes back what it added, and the warning has to say so before the fact
    /// rather than after.
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
                // Mid-run, going back is a destructive act wearing the chrome of
                // a navigation control — the same reason stopping downloads
                // asks first.
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
            // Not disabled during a run any more. It was, and a greyed-out
            // "< Connections" sitting next to a subtitle promising you can keep
            // using the app read as the window having locked up — which is
            // exactly the impression this whole page is trying not to give.
            // Leaving already stops the import (`onDisappear`), so the button
            // has a defined meaning; it just says so now.
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
                        // Bounded on purpose. An unbounded `fixedSize` here
                        // measured against the narrow settings column and locked
                        // in a minimum height taller than the window, which
                        // pushed everything below off screen and set AppKit
                        // re-running Update Constraints until it gave up.
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

    /// One button, same rule as the sheet: connect, then import, then done.
    /// It sits in the header beside the title rather than in a bottom bar, so
    /// it stays put while the listing scrolls and is visible the moment the
    /// page opens.
    private var actions: some View {
        HStack(spacing: 10) {
            // Secondary, never in place of Import: the banner above asks for a
            // reconnect, and until now the page explained the problem and
            // offered no way to act on it — but an old connection still lists
            // playlists, and importing those has to stay one click away.
            if auth.isAuthorized, auth.needsReauthorization, model.phase != .migrating {
                Button("Reconnect") { model.connect() }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .disabled(model.isConnecting)
            }

            primaryButton
        }
        // Horizontal only: the row must keep its intrinsic width when the
        // settings column is measured narrow, but must never be free to grow
        // taller than one line.
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
