// Routes between auth and the main app, and handles mixtape:// links.
// Invite links are redeemed here; auth links go to authService.handleDeepLink.

import SwiftUI
import OSLog
import CoreSpotlight

public struct RootView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDownloadPrompt = false
    /// An invite, Jam or Blend link that arrived before the main screen was up.
    @State private var pendingLink: URL?
    @AppStorage(InviteNotifier.askedKey) private var askedNotifications = false
    @State private var askNotifications = false

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
            // First `.task` runs after the first frame.
            LaunchTimeline.firstWindowVisible()
            await deps.restoreSessionIfNeeded()
            MixLog.launch.notice("Session restored at \(LaunchTimeline.elapsedMilliseconds(), privacy: .public) ms")
            // onChange skips the initial value, so check once on launch too.
            await refreshInvites()
            deps.jam.nearby.watch(deps.isAuthenticated)
            MixLog.launch.notice("Invites refreshed at \(LaunchTimeline.elapsedMilliseconds(), privacy: .public) ms")

            // Last, once the session is settled.
            deps.artworkCompaction.startIfNeeded()
        }
        // Poll the inbox while the app is open, in case realtime has quietly dropped.
        .task(id: deps.isAuthenticated) {
            guard deps.isAuthenticated else { return }
            while !Task.isCancelled {
                // Once per device, and never over another sheet: a later pass asks instead.
                // Read the store: this task's copy of self keeps the @AppStorage value it started with.
                if !UserDefaults.standard.bool(forKey: InviteNotifier.askedKey) && !showDownloadPrompt && !deps.authService.pendingUsernameSelection {
                    askNotifications = true
                }
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                await refreshInvites()
            }
        }
        .onChange(of: deps.isAuthenticated) { _, isAuth in
            checkPrompt(isAuth: isAuth)
            // The next account's inbox isn't this one's.
            if !isAuth { InviteNotifier.shared.reset() }
            deps.jam.nearby.watch(isAuth)
            Task { await refreshInvites() }
        }
        // Check invites when returning to the app.
        .onChange(of: scenePhase) { _, phase in
            // Pauses looping animations while hidden.
            AppVisibility.shared.update(phase)

            switch phase {
            case .active:
                Analytics.appBecameActive()
                CrashReporter.flushErrors()
                Task { await refreshInvites() }
                // Realtime dies in the background, so rebuild it and pull once.
                deps.syncService.resumeRealtime()
                // Watched folders may have changed while away. No-op without folders.
                deps.localFiles.rescan()
                // A new month's recap, or one another device built.
                Task { await deps.recap.refresh() }
            case .background:
                // Background refresh can only be scheduled while the app is alive.
                InviteNotifier.shared.scheduleBackgroundRefresh()
                CrashReporter.flushErrors()
            default:
                break
            }
        }
        .onAppear {
            checkPrompt(isAuth: deps.isAuthenticated)
            #if os(iOS)
            ToastWindow.install(deps)
            #endif
        }
        // Invite links are handled before handleDeepLink, which would treat the
        // code as an auth callback. Spotlight hits go to SpotlightIndex.
        .onContinueUserActivity(CSSearchableItemActionType) { SpotlightIndex.open($0) }
        .onOpenURL { open($0) }
        .onChange(of: isReady) { _, ready in
            guard ready, let url = pendingLink else { return }
            pendingLink = nil
            open(url)
        }
        #if DEBUG && os(macOS)
        .task(id: isReady) { if isReady { await ScreenshotSetup.run(deps) } }
        #endif
        // Answered once it's seen, so quitting with it open doesn't bring it back.
        .sheet(isPresented: $askNotifications) {
            NotificationsPrompt()
                .onAppear { askedNotifications = true }
        }
        // Password reset is handled inline in the auth screens.
        .modifier(NewCratePrompt(library: deps.libraryService))
        .sheet(isPresented: $showDownloadPrompt) {
            WelcomeDownloadPrompt()
                .environment(exportManager)
        }
        // First social sign-in: offer to replace the generated username. Skippable.
        .sheet(isPresented: Binding(
            get: { deps.authService.pendingUsernameSelection },
            set: { if !$0 { deps.authService.dismissUsernamePrompt() } }
        )) {
            UsernamePromptView(authService: deps.authService)
        }
        .background(JamSheetPresenter(jam: deps.jam))
        #if os(macOS)
        .overlay { RecapPresenter(recap: deps.recap) }
        #else
        .background(RecapPresenter(recap: deps.recap))
        #endif
        // The backdrop colour is laid out against the whole window.
        // Size plus insets: ignoresSafeArea here still reports the safe size, which left the image short of the bottom.
        .background {
            Color.clear
                .onGeometryChange(for: CGSize.self) { p in
                    let i = p.safeAreaInsets
                    return CGSize(width: p.size.width + i.leading + i.trailing, height: p.size.height + i.top + i.bottom)
                } action: { BackdropRenderer.shared.fieldSize = $0 }
        }
    }

    /// Redirects an ASWebAuthenticationSession is already waiting on. Handling them
    /// here too would redeem the one-time auth code twice and fail.
    /// Only the email flows (confirm, reset-password) arrive cold.
    private static func isHandledByAnAuthSession(_ url: URL) -> Bool {
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return target == "auth-callback" || target == "spotify-callback"
    }

    // MARK: Invite links

    /// The share code in an invite URL, or nil. Accepts mixtape://join/CODE,
    /// https://mixtaped.tech/join/CODE and ?code=CODE; `kind: "jam"` reads Jam links the same way.
    static func inviteCode(from url: URL, kind: String = "join") -> String? {
        var segments = url.path.split(separator: "/").map(String.init)
        // mixtape://jam/CODE has the kind as its host; https links have it in the path.
        if url.host?.lowercased() != kind {
            guard segments.first?.lowercased() == kind else { return nil }
            segments.removeFirst()
        }
        if let first = segments.first { return normalisedCode(first) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        return query.flatMap(normalisedCode)
    }

    /// Links from chat apps can arrive lowercased or with a trailing slash.
    nonisolated private static func normalisedCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.count >= 4 ? code : nil
    }

    /// Signed in with the main screen showing, where joins can show their messages and sheets.
    private var isReady: Bool { deps.isAuthenticated && !deps.isRestoringSession }

    private func open(_ url: URL) {
        if let code = Self.inviteCode(from: url) {
            whenReady(url) { await redeemInvite(code) }
        } else if let code = Self.inviteCode(from: url, kind: "jam") {
            whenReady(url) { await deps.jam.join(code: code) }
        } else if let code = Self.inviteCode(from: url, kind: "blend") {
            whenReady(url) { await deps.blends.join(code: code) }
        } else if Self.isHandledByAnAuthSession(url) {
            // Deliberately nothing. See the note on the function.
        } else {
            Task { await deps.authService.handleDeepLink(url) }
        }
    }

    /// A link that opens the app, or arrives signed out, waits for sign-in and the splash to finish.
    private func whenReady(_ url: URL, _ join: @escaping () async -> Void) {
        guard isReady else { pendingLink = url; return }
        Task { await join() }
    }

    private func redeemInvite(_ code: String) async {
        do {
            let result = try await PlaylistSharingService.shared
                .redeemInvite(code: code, libraryService: deps.libraryService)
            let id = result.localPlaylistID
            deps.showToast(Toast.done(result.alreadyHere
                                      ? "\u{201C}\(result.record.name)\u{201D} is already in your library"
                                      : "Joined \u{201C}\(result.record.name)\u{201D}")
                .action("View") { Toast.openPlaylist(id) })
            try? await deps.syncService.sync()
            // Joining via link also accepts any direct invite, so refresh the inbox.
            await refreshInvites()
        } catch {
            deps.showToast(.failed("That invite link isn't valid any more", error))
        }
    }

    /// Re-reads the inbox and messages, which announce anything new. Pending invites too, for Accept.
    private func refreshInvites() async {
        await InboxService.shared.refresh()
        await MessagesService.shared.refresh()
        await PlaylistSharingService.shared.refreshPendingInvites()
        // Daily at most, so the poll is fine.
        await InviteNotifier.shared.checkNewReleases()
    }

    private func checkPrompt(isAuth: Bool) {
        guard isAuth else { return }
        // Only prompt if no location was ever confirmed or skipped.
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
        .environment(AppDependencies())
}
