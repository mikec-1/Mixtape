// RootView.swift
// Mixtape — App
//
// Gate between the auth flow and the main app.
// Reads isAuthenticated from AppDependencies and routes accordingly.
//
// Every mixtape:// deep link arrives here, and there are two kinds. Playlist
// invites (mixtape://join/<CODE>) are redeemed locally. Everything else — email
// confirmation, password reset — goes to authService.handleDeepLink(url), and
// the SDK fires an authStateChanges event which updates authState /
// isAwaitingPasswordReset.

import SwiftUI
import OSLog

public struct RootView: View {

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var exportManager: ExportManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDownloadPrompt = false
    /// An invite tapped before there was an account to join it with.
    @State private var pendingInviteCode: String?
    /// Invites already toasted about, so returning to the app doesn't re-announce
    /// the same one every time. Deliberately not persisted: once per launch is
    /// the right amount of nagging for something still waiting on an answer.
    @State private var announcedInvites: Set<UUID> = []

    public var body: some View {
        let _ = LaunchTimeline.markOnce("root-view/first-body")
        return Group {
            if deps.isRestoringSession {
                SplashView()
            } else if deps.isAuthenticated {
                #if os(macOS)
                MacRootView()
                    .transition(.opacity)
                #else
                MainTabView()
                    .transition(.opacity)
                #endif
            } else {
                #if os(macOS)
                MacAuthFlowView(authService: deps.authService)
                    .transition(.opacity)
                #else
                SignInView(authService: deps.authService)
                    .transition(.opacity)
                #endif
            }
        }
        .mixAnimation(.easeInOut(duration: 0.35), value: deps.isAuthenticated)
        .mixAnimation(.easeInOut(duration: 0.45), value: deps.isRestoringSession)
        .task {
            // The first `.task` on the root view runs after the first frame has
            // been submitted, which is the closest thing SwiftUI offers to "the
            // window is on screen and takes input".
            LaunchTimeline.firstWindowVisible()

            await deps.restoreSessionIfNeeded()
            MixLog.launch.notice("Session restored at \(LaunchTimeline.elapsedMilliseconds(), privacy: .public) ms")
            // Not covered by the onChange below. A launch that restores a session
            // synchronously never *changes* isAuthenticated, and .onChange skips
            // the initial value, so a cold start into a signed-in account could
            // sit there having never once looked at the inbox.
            await refreshInvites()
            MixLog.launch.notice("Invites refreshed at \(LaunchTimeline.elapsedMilliseconds(), privacy: .public) ms")

            // Last, and only after the session is settled: a wipe or an account
            // switch would cancel it anyway, so there is nothing to gain from
            // starting it any earlier — and a cold launch has better things to
            // do with the disk.
            deps.artworkCompaction.startIfNeeded()
        }
        // While the app is open, keep looking. Sixty seconds is far longer than a
        // push would take and far cheaper than the polling that would be needed
        // to *feel* like push — the point is only that an invite arriving while
        // someone is using the app doesn't wait for them to background it first.
        .task(id: deps.isAuthenticated) {
            guard deps.isAuthenticated else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                await refreshInvites()
            }
        }
        .onChange(of: deps.isAuthenticated) { _, isAuth in
            checkPrompt(isAuth: isAuth)
            // Signing out has to clear these too: the next account's invites are
            // not this one's, and an un-cleared set would swallow their toast.
            announcedInvites = []
            if !isAuth { InviteNotifier.shared.reset() }
            Task {
                if isAuth { await InviteNotifier.shared.requestAuthorizationIfNeeded() }
                await refreshInvites()
            }
        }
        // Returning to the app is the moment a user is most likely to be looking
        // for the playlist a friend just told them about, which makes it the
        // cheapest place to check.
        .onChange(of: scenePhase) { _, phase in
            // Stops the app's looping animations while nobody can see them —
            // see `AppVisibility` for what that was costing.
            AppVisibility.shared.update(phase)

            switch phase {
            case .active:
                Task { await refreshInvites() }
                // The Realtime websocket does not survive being backgrounded,
                // and a dead channel is silent rather than loud — so rebuild it
                // here and take one pull for whatever changed while away.
                deps.syncService.resumeRealtime()
                // Coming back is also when a watched folder is most likely to
                // have changed — the user has just been in Finder or the Files
                // app moving music around. The scan is derived and cheap, and it
                // no-ops entirely when no folder is being watched.
                deps.localFiles.rescan()
            case .background:
                // A BGAppRefreshTaskRequest can only be submitted while the app is
                // alive, so leaving is the last chance to ask for the background
                // slot that delivers an invite arriving after this point.
                InviteNotifier.shared.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .onAppear {
            checkPrompt(isAuth: deps.isAuthenticated)
        }
        // ── Deep link handler ──
        // mixtape://join/<CODE> is an invite to a collaborative playlist and has
        // nothing to do with auth, so it branches out before handleDeepLink —
        // which would otherwise hand a share code to client.auth.session(from:).
        // Everything else (email confirmation, password reset) shares the scheme
        // and goes through the SDK, which fires the matching authStateChanges event.
        .onOpenURL { url in
            if let code = Self.inviteCode(from: url) {
                Task { await redeemInvite(code) }
            } else if Self.isHandledByAnAuthSession(url) {
                // Deliberately nothing. See the note on the function.
            } else {
                Task { await deps.authService.handleDeepLink(url) }
            }
        }
        .onChange(of: deps.isAuthenticated) { _, isAuth in
            // A link tapped while signed out is held rather than dropped: the
            // sign-in that follows is almost always *because* of the link, and
            // losing it means asking the sender for it again.
            guard isAuth, let code = pendingInviteCode else { return }
            pendingInviteCode = nil
            Task { await redeemInvite(code) }
        }
        // Password reset is handled inline in MacAuthFlowView / SignInView.
        // isAwaitingPasswordReset keeps authState = .unauthenticated so the user
        // lands on the auth screen, which navigates to the Set New Password screen.
        .sheet(isPresented: $showDownloadPrompt) {
            WelcomeDownloadPrompt()
                .environmentObject(exportManager)
        }
        // First social sign-in: invite the user (once) to pick a real username
        // instead of the auto-generated user_xxxx. Non-blocking — they can skip.
        .sheet(isPresented: Binding(
            get: { deps.authService.pendingUsernameSelection },
            set: { if !$0 { deps.authService.dismissUsernamePrompt() } }
        )) {
            UsernamePromptView(authService: deps.authService)
        }
    }

    /// True for the redirects that belong to an `ASWebAuthenticationSession`
    /// already waiting on them, which this view must therefore leave alone.
    ///
    /// Google sign-in returns through `mixtape://auth-callback`, and the auth
    /// code in it may be redeemed exactly once — the server drops the flow state
    /// on the first exchange. The session started by `signInWithGoogle()` catches
    /// that URL and does the exchange itself. When the same URL *also* reached
    /// `onOpenURL`, this ran a second exchange against a code that was already
    /// spent, and the server answered "invalid flow state, no valid flow state
    /// found" — which is the error that surfaced, on the sign-in screen, after an
    /// otherwise perfectly good Google sign-in.
    ///
    /// `mixtape://spotify-callback` is the same story with a different owner:
    /// `SpotifyAuth` runs its own session, and handing its code to Supabase's
    /// auth client was never going to do anything but fail.
    ///
    /// Only the email flows — `mixtape://confirm`, `mixtape://reset-password` —
    /// genuinely arrive cold, from Mail, with nothing in the app waiting for them.
    private static func isHandledByAnAuthSession(_ url: URL) -> Bool {
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return target == "auth-callback" || target == "spotify-callback"
    }

    // MARK: Invite links

    /// The share code in an invite URL, or nil if this isn't one.
    ///
    /// Both shapes are parsed today even though only the first can arrive today:
    /// `mixtape://join/ABC123`, and `https://mixtaped.tech/join/ABC123` for when
    /// that page exists. Universal links come in through
    /// `NSUserActivityTypeBrowsingWeb` rather than `onOpenURL`, so switching over
    /// still needs an Associated Domains entitlement and a second handler — but
    /// it won't need this function rewritten, and every `mixtape://` invite
    /// already sent keeps working because this branch never goes away.
    static func inviteCode(from url: URL) -> String? {
        let segments = url.path.split(separator: "/").map(String.init)

        if url.host?.lowercased() == "join" {
            if let first = segments.first { return normalisedCode(first) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
            return query.flatMap(normalisedCode)
        }

        if segments.first?.lowercased() == "join", segments.count >= 2 {
            return normalisedCode(segments[1])
        }

        return nil
    }

    /// Codes are generated uppercase from a 32-character alphabet, but a link
    /// that's been through a chat app can arrive lowercased or with a stray
    /// trailing slash, and the RPC matches exactly.
    private static func normalisedCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.count >= 4 ? code : nil
    }

    private func redeemInvite(_ code: String) async {
        guard deps.isAuthenticated else {
            pendingInviteCode = code
            deps.showToast("Sign in to join this playlist")
            return
        }

        do {
            let result = try await PlaylistSharingService.shared
                .redeemInvite(code: code, libraryService: deps.libraryService)
            deps.showToast(result.alreadyHere
                           ? "\u{201C}\(result.record.name)\u{201D} is already in your library"
                           : "Joined \u{201C}\(result.record.name)\u{201D}")
            try? await deps.syncService.sync()
            // Following the link for a playlist you were *also* directly invited
            // to joins you outright — the RPC upgrades the membership row — so
            // the pending card has to go, or it sits there offering something
            // that's already in the library.
            await refreshInvites()
        } catch {
            deps.showToast("That invite link isn't valid any more")
        }
    }

    /// Re-reads the invite inbox and announces anything new.
    ///
    /// Not guarded on `isAuthenticated`: `refreshPendingInvites` empties the list
    /// when there's no session, which is exactly what should happen on sign-out.
    private func refreshInvites() async {
        let sharing = PlaylistSharingService.shared
        await sharing.refreshPendingInvites()

        // A banner and a toast for the same invite on the same screen is the news
        // twice. Whichever surface the user is actually looking at wins.
        let foreground = scenePhase == .active
        await InviteNotifier.shared.announce(sharing.pendingInvites, suppressBanner: foreground)

        guard foreground else { return }
        let fresh = sharing.pendingInvites.filter { !announcedInvites.contains($0.id) }
        guard !fresh.isEmpty else { return }
        announcedInvites.formUnion(fresh.map(\.id))

        if fresh.count == 1, let invite = fresh.first {
            deps.showToast(InviteNotifier.body(for: invite))
        } else {
            deps.showToast("You have \(fresh.count) playlist invites")
        }
    }

    private func checkPrompt(isAuth: Bool) {
        guard isAuth else { return }
        // Show prompt only if the user has never confirmed a location and hasn't
        // explicitly skipped. isLocationConfigured is set by ExportManager.setExportURL
        // so it survives bookmark resolution failures on subsequent launches.
        if !exportManager.isLocationConfigured && !exportManager.didSkip {
            showDownloadPrompt = true
        }
    }
}

// MARK: - Splash / Loading Screen

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: MixtapeMark.symbolName)
                    .font(.system(size: 64))
                    .foregroundStyle(Color.mixPrimary)
                    .mixPulse()
                Text("Mixtape")
                    .font(.mixDisplay)
                    .foregroundStyle(Color.mixTextPrimary)
                    .mixTightened()
            }
        }
    }
}

// MARK: - Preview

#Preview("Unauthenticated") {
    RootView()
        .environmentObject(AppDependencies())
}
