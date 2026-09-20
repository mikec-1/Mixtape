// SupabaseAuthService.swift
// Mixtape — Core/Services
//
// Auth service backed by Supabase.
//
// Session persistence is handled automatically by the supabase-swift SDK:
// it stores the refresh token in the Keychain and silently refreshes JWTs.
// This service observes the authStateChanges stream.

import Foundation
import Supabase
import Combine
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
public final class SupabaseAuthService: ObservableObject, AuthServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var authState: AuthState = .loading {
        didSet {
            // Scope per-account EQ to the signed-in user so settings don't leak
            // between accounts on a shared Mac.
            if case .authenticated(let user) = authState {
                AudioEqualizer.currentUserID = user.id.uuidString
                // The account's playlist order travels with it, so a phone and
                // a Mac signed into the same account read the same list the
                // same way. See `PlaylistSortSyncService`.
                PlaylistSortSyncService.shared.adoptRemote(user.playlistSortOrder)
                PlaylistTrackSortService.shared.adoptRemote(user.playlistTrackSorts)
                SpotifyImportLedger.shared?.adoptRemote(user.spotifyImports)
                SavedAlbumsService.shared.adoptRemote(user.savedAlbums)
                SpotifyFollowService.shared?.adoptRemote(user.spotifyLinks)
            } else {
                AudioEqualizer.currentUserID = nil
            }
        }
    }

    /// True while the app is running on a cached session because the token
    /// could not be refreshed. The user is *signed in* — there is a refresh
    /// token in the Keychain and music on the disk — there is simply no server
    /// to confirm it with. Conflating that with "signed out" is what used to
    /// bounce a plane passenger to the login screen. See `enterOffline`.
    @Published private(set) public var isOffline: Bool = false

    /// True when the user has clicked a password-reset link and must set a new password
    /// before being allowed into the main app. The Supabase session is alive (for the
    /// updatePassword call) but authState is kept .unauthenticated until the update completes.
    @Published public private(set) var isAwaitingPasswordReset: Bool = false

    /// True after signUp() when Supabase requires email confirmation.
    /// Cleared automatically when the confirmation deep link fires.
    @Published public private(set) var pendingEmailConfirmation: Bool = false

    /// True after a *social* sign-in (Apple / Google) when the user still has the
    /// auto-generated `user_xxxxxxxx` username assigned by the DB trigger and should
    /// be invited (once, non-blocking) to pick a real one. Observed by RootView.
    @Published public private(set) var pendingUsernameSelection: Bool = false

    /// A suggested username derived from the provider profile (e.g. Apple full name),
    /// used to pre-fill the username prompt. nil when nothing usable was provided.
    public private(set) var suggestedUsername: String?
    /// The provider's name as given ("Mike Smith"), to pre-fill the display name.
    public private(set) var suggestedDisplayName: String?
    /// The prompt is only asking for a display name: accounts from before
    /// display names existed, which already have a real username.
    @Published public private(set) var promptNameOnly = false
    private var checkedDisplayName = false

    // MARK: - Protocol

    public var authStatePublisher: AnyPublisher<AuthState, Never> {
        $authState.eraseToAnyPublisher()
    }

    public var currentUser: AppUser? {
        if case .authenticated(let user) = authState { return user }
        return nil
    }

    public private(set) var accessToken: String?

    // MARK: - Private

    // Held as a provider rather than a value: building the SupabaseClient costs
    // ~1.3 s and, taken eagerly in `AppDependencies.init`, that whole second sat
    // on the main thread before the first frame. `@autoclosure` keeps every call
    // site written exactly as before while moving the work to first real use —
    // which is a network call, and so already off the launch path.
    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    private var listenerTask: Task<Void, Never>?

    /// Continuation used by restoreSession() to wait for the first SDK event.
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    private var didReceiveInitialEvent = false

    // MARK: - Init

    public init(client: @autoclosure @escaping () -> SupabaseClient) {
        self.clientProvider = client
        startListening()
    }

    deinit {
        listenerTask?.cancel()
    }

    // MARK: - Stream

    private func startListening() {
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in client.auth.authStateChanges {
                guard !Task.isCancelled else { break }
                self.handleEvent(event: event, session: session)
            }
        }
    }

    private func handleEvent(event: AuthChangeEvent, session: Session?) {
        switch event {

        case .passwordRecovery:
            // User clicked a password-reset link.
            // Store the session token so updatePassword() can authenticate, but
            // keep authState as .unauthenticated so RootView doesn't enter the app.
            accessToken = session?.accessToken
            isAwaitingPasswordReset = true
            authState = .unauthenticated

        case .signedOut:
            // The one event that really means signed out. Everything else that
            // arrives without a session is "couldn't ask", not "no".
            Self.clearCachedUser()
            accessToken = nil
            isOffline = false
            authState = .unauthenticated
            isAwaitingPasswordReset = false
            pendingEmailConfirmation = false
            pendingUsernameSelection = false
            promptNameOnly = false
            checkedDisplayName = false
            suggestedUsername = nil
            suggestedDisplayName = nil

        default:
            // .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified …
            if let session {
                accessToken = session.accessToken
                isOffline = false
                cache(makeUser(from: session))
                pendingEmailConfirmation = false        // confirmed (or confirmation not required)
                if event == .userUpdated {
                    // Password update complete — clear the gate and admit the user.
                    isAwaitingPasswordReset = false
                    authState = .authenticated(makeUser(from: session))
                } else if !isAwaitingPasswordReset {
                    authState = .authenticated(makeUser(from: session))
                    if event == .initialSession || event == .signedIn {
                        Task { await checkDisplayNamePrompt() }
                    }
                }
                // If isAwaitingPasswordReset is still true (a follow-on token event fired
                // after .passwordRecovery), we deliberately do NOT authenticate —
                // the user must set a new password before entering the app.
            } else if !isAwaitingPasswordReset {
                // Don't wipe auth state while waiting for password update
                accessToken = nil
                if !enterOffline() { authState = .unauthenticated }
            }
        }

        // Resume restoreSession() on the first SDK event regardless of type.
        if !didReceiveInitialEvent {
            didReceiveInitialEvent = true
            restoreContinuation?.resume()
            restoreContinuation = nil
        }
    }

    // MARK: - Offline Session

    private static let cachedUserKey = "mix.cachedUser"
    private static let lastOnlineAuthKey = "mix.lastOnlineAuth"
    /// How long a device may run on a cached session before it has to prove
    /// itself online again. The user asked for a week.
    private static let offlineGrace: TimeInterval = 7 * 24 * 60 * 60

    private func cache(_ user: AppUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedUserKey)
        UserDefaults.standard.set(Date(), forKey: Self.lastOnlineAuthKey)
    }

    private static func clearCachedUser() {
        UserDefaults.standard.removeObject(forKey: cachedUserKey)
        UserDefaults.standard.removeObject(forKey: lastOnlineAuthKey)
    }

    /// Enters the app on the last known user when the token could not be
    /// refreshed. Returns false — leaving the caller to show the login screen —
    /// when there is no cached user or the week is up.
    @discardableResult
    private func enterOffline() -> Bool {
        guard !isAwaitingPasswordReset,
              let data = UserDefaults.standard.data(forKey: Self.cachedUserKey),
              let user = try? JSONDecoder().decode(AppUser.self, from: data),
              let last = UserDefaults.standard.object(forKey: Self.lastOnlineAuthKey) as? Date,
              Date().timeIntervalSince(last) < Self.offlineGrace
        else { return false }
        isOffline = true
        authState = .authenticated(user)
        return true
    }

    /// Asks the server again. Called when the network comes back: the SDK's own
    /// refresh timer was set (or cancelled) while there was nothing to talk to,
    /// so it is not guaranteed to try on its own. A success arrives as a normal
    /// `.tokenRefreshed` event and clears `isOffline` through `handleEvent`.
    public func retryOnlineAuth() async {
        guard isOffline else { return }
        _ = try? await client.auth.refreshSession()
    }

    // MARK: - Session Restore

    /// Waits for the SDK to fire its initial auth event (max 5 s),
    /// then returns. authState will be .authenticated or .unauthenticated.
    public func restoreSession() async {
        guard !didReceiveInitialEvent else { return }

        await withCheckedContinuation { continuation in
            if didReceiveInitialEvent {
                continuation.resume()
            } else {
                restoreContinuation = continuation
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if !self.didReceiveInitialEvent {
                        self.didReceiveInitialEvent = true
                        self.restoreContinuation?.resume()
                        self.restoreContinuation = nil
                        if !self.enterOffline() { self.authState = .unauthenticated }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    public func signIn(email: String, password: String) async throws {
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw map(error)
        }
    }

    // MARK: Social Sign-In

    /// Signs in with Google.
    ///
    /// This drives the flow through the SDK's `launchFlow` overload rather than
    /// its `ASWebAuthenticationSession` convenience, because we need two things
    /// that overload doesn't give us: our own presentation anchor, and sight of
    /// the callback URL before it is exchanged.
    ///
    /// The anchor matters because the SDK's fallback is a bare
    /// `ASPresentationAnchor()` — an `NSWindow` on macOS, which works, and on
    /// iOS a `UIWindow` with no scene attached, which can present nothing.
    ///
    /// The session is deliberately *not* ephemeral. An ephemeral one shares no
    /// cookies with the browser, which on iOS means Google's account chooser is
    /// always empty and on macOS means the system opens a private window rather
    /// than the browser the user already has signed in. It was ephemeral once,
    /// to guard against a replayed `mixtape://auth-callback?code=…`, but the two
    /// real causes of `flow_state_not_found` were both found and fixed at the
    /// source since: `RootView.onOpenURL` redeeming the same code a second time
    /// (it now ignores `auth-callback`), and a stray `#` glued onto the code by
    /// a GoTrue Site-URL fallback (`cleanedCallback(_:)`). So the flag was only
    /// costing the account chooser. `SpotifyAuth` has always used `false` here.
    public func signInWithGoogle() async throws {
        do {
            let anchor = OAuthPresentationAnchorProvider()
            try await client.auth.signInWithOAuth(
                provider:   .google,
                redirectTo: URL(string: "mixtape://auth-callback")
            ) { @MainActor url in
                return try await withCheckedThrowingContinuation { continuation in
                    let session = ASWebAuthenticationSession(
                        url: url,
                        callbackURLScheme: "mixtape"
                    ) { callback, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let callback {
                            continuation.resume(returning: Self.cleanedCallback(callback))
                        } else {
                            continuation.resume(throwing: AuthErrorMissingCallback())
                        }
                    }
                    session.prefersEphemeralWebBrowserSession = false
                    session.presentationContextProvider = anchor
                    session.start()
                }
            }
            withExtendedLifetime(anchor) {}
            await reconcileProfileAvatar()
            await checkUsernamePrompt()
        } catch {
            print("[Auth] ❌ Google sign-in failed: \(error) — \(error.localizedDescription)")
            throw map(error)
        }
    }

    /// Google overwrites `user_metadata.avatar_url` with the Google photo on each
    /// sign-in, which would shadow a custom avatar the user uploaded. The custom
    /// avatar lives in `profiles.avatar_url` (untouched by OAuth), so if one is
    /// set we re-assert it into auth metadata. Best-effort; failures are ignored.
    private func reconcileProfileAvatar() async {
        guard let userID = client.auth.currentUser?.id,
              let custom = try? await fetchProfileAvatarURL(userID: userID),
              !custom.isEmpty else { return }

        let currentMeta: String? = {
            if case .string(let raw)? = client.auth.currentUser?.userMetadata["avatar_url"] { return raw }
            return nil
        }()
        guard currentMeta != custom else { return }
        try? await client.auth.update(user: UserAttributes(data: ["avatar_url": .string(custom)]))
    }

    private struct ProfileAvatarRow: Decodable { let avatar_url: String? }

    /// The custom avatar URL stored in the user's `profiles` row, if any.
    private func fetchProfileAvatarURL(userID: UUID) async throws -> String? {
        let rows: [ProfileAvatarRow] = try await client
            .from("profiles")
            .select("avatar_url")
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.avatar_url
    }

    /// After a social sign-in, raises `pendingUsernameSelection` unless the user
    /// has already completed the prompt once (tracked by a `username_chosen` flag
    /// in their auth metadata). Deterministic — doesn't depend on guessing the
    /// trigger-assigned username. Best-effort; failures are silently ignored.
    private func checkUsernamePrompt() async {
        let metadata = client.auth.currentUser?.userMetadata ?? [:]

        // Already chosen (or explicitly skipped) — don't nag again.
        if case .bool(true)? = metadata["username_chosen"] { return }

        // The metadata flag is only written on the social path. An account that
        // signed up by email (then later signs in with Google to the SAME
        // account) already has a real username in `profiles` but no flag — so
        // treat any non-auto-generated username as already chosen and skip the
        // prompt (persisting the flag so we don't re-query next time).
        if let userID = client.auth.currentUser?.id,
           let existing = try? await fetchProfileUsername(userID: userID),
           !isAutoGeneratedUsername(existing) {
            try? await client.auth.update(user: UserAttributes(data: ["username_chosen": .bool(true)]))
            return
        }

        // Pre-fill a suggestion from the provider's name, if any.
        let nameKeys = ["full_name", "name", "display_name"]
        for key in nameKeys {
            if case .string(let raw)? = metadata[key] {
                if suggestedDisplayName == nil, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestedDisplayName = raw.trimmingCharacters(in: .whitespaces)
                }
                let cleaned = raw
                    .lowercased()
                    .unicodeScalars
                    .filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }
                    .map(String.init)
                    .joined()
                if !cleaned.isEmpty { suggestedUsername = cleaned; break }
            }
        }

        promptNameOnly = false
        pendingUsernameSelection = true
    }

    /// Once per account: asks someone who has a real username but never set a
    /// display name for one, pre-filled with the username. Skipping or saving
    /// writes `display_name_chosen`, so it never asks again.
    private func checkDisplayNamePrompt() async {
        guard !checkedDisplayName, !pendingUsernameSelection,
              let userID = client.auth.currentUser?.id else { return }
        checkedDisplayName = true
        if case .bool(true)? = client.auth.currentUser?.userMetadata["display_name_chosen"] { return }
        // A placeholder username is the full prompt's job (checkUsernamePrompt).
        guard let profile = try? await fetchProfile(id: userID),
              !isAutoGeneratedUsername(profile.username) else { return }
        if profile.displayName != nil {
            try? await client.auth.update(user: UserAttributes(data: ["display_name_chosen": .bool(true)]))
            return
        }
        guard !pendingUsernameSelection else { return }
        suggestedDisplayName = profile.username
        promptNameOnly = true
        pendingUsernameSelection = true
    }

    private struct ProfileUsernameRow: Decodable { let username: String? }

    /// The current username stored in the user's `profiles` row, if any.
    private func fetchProfileUsername(userID: UUID) async throws -> String? {
        let rows: [ProfileUsernameRow] = try await client
            .from("profiles")
            .select("username")
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.username
    }

    /// True for the DB trigger's placeholder username (`user_` + 8 hex chars),
    /// i.e. a username the user has NOT chosen yet.
    private func isAutoGeneratedUsername(_ name: String) -> Bool {
        name.range(of: "^user_[0-9a-f]{8}$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Completes a social sign-up: sets the chosen username and, optionally, a
    /// password so the user can also sign in with email next time. The account
    /// already has a verified email (from Google), so attaching a password simply
    /// adds an email/password credential to the same account. Then clears the prompt.
    public func chooseUsername(_ name: String, displayName: String = "", password: String? = nil) async throws {
        try await updateUsername(name)
        if !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await updateDisplayName(displayName)
        }
        do {
            if let password, !password.isEmpty {
                guard password.count >= 8 else { throw AuthError.weakPassword }
                try await client.auth.update(user: UserAttributes(password: password))
            }
            // Mark the prompt as completed so it never shows again.
            try await client.auth.update(user: UserAttributes(data: [
                "username_chosen": .bool(true), "display_name_chosen": .bool(true)
            ]))
        } catch let error as AuthError {
            throw error
        } catch {
            throw map(error)
        }
        pendingUsernameSelection = false
        promptNameOnly = false
        suggestedUsername = nil
        suggestedDisplayName = nil
    }

    /// Dismisses the username prompt (Skip / swipe-down) and remembers the choice so
    /// it isn't shown again, keeping the auto-assigned username.
    public func dismissUsernamePrompt() {
        Task { try? await client.auth.update(user: UserAttributes(data: [
            "username_chosen": .bool(true), "display_name_chosen": .bool(true)
        ])) }
        pendingUsernameSelection = false
        promptNameOnly = false
        suggestedUsername = nil
        suggestedDisplayName = nil
    }

    public func isUsernameTaken(_ username: String) async throws -> Bool {
        struct ProfileCheck: Decodable {
            let id: UUID
        }
        
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("[SupabaseAuthService] Checking if username '\(cleaned)' is taken...")
        do {
            let response: [ProfileCheck] = try await client.from("profiles")
                .select("id")
                .eq("username", value: cleaned)
                .limit(1)
                .execute()
                .value
            let taken = !response.isEmpty
            print("[SupabaseAuthService] Username '\(cleaned)' taken check result: \(taken) (found \(response.count) rows)")
            return taken
        } catch {
            print("[SupabaseAuthService] isUsernameTaken error for '\(cleaned)': \(error)")
            throw error
        }
    }

    /// Signs up a new user.
    /// Returns `true` when Supabase requires email confirmation before the session is active.
    @discardableResult
    public func signUp(email: String, password: String, username: String, displayName: String) async throws -> Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        do {
            let response = try await client.auth.signUp(
                email:    email,
                password: password,
                // The profiles trigger reads both: `display_name` seeds the column.
                data:     [
                    "username": AnyJSON.string(cleanUsername),
                    "display_name": AnyJSON.string(name.isEmpty ? cleanUsername : name)
                ]
            )
            // session == nil means Supabase has "Email Confirmations" enabled
            // and the user must click the link before they're signed in.
            let requiresConfirmation = (response.session == nil)
            if requiresConfirmation {
                pendingEmailConfirmation = true
            }
            return requiresConfirmation
        } catch {
            throw map(error)
        }
    }

    /// This device only unless `everywhere`. The SDK's own default is global,
    /// which made signing out here — or revoking one device from the web —
    /// sign out every device on the account.
    public func signOut(everywhere: Bool = false) async throws {
        do {
            try await client.auth.signOut(scope: everywhere ? .global : .local)
        } catch {
            throw map(error)
        }
    }

    public func resetPassword(email: String) async throws {
        do {
            try await client.auth.resetPasswordForEmail(
                email,
                redirectTo: URL(string: "mixtape://reset-password")
            )
        } catch {
            throw map(error)
        }
    }

    /// Re-sends the confirmation email for a pending signup.
    public func resendConfirmation(email: String) async throws {
        do {
            try await client.auth.resend(
                email: email,
                type:  .signup,
                emailRedirectTo: URL(string: "mixtape://confirm")
            )
        } catch {
            throw map(error)
        }
    }

    /// Updates the current user's password. Requires a live recovery session
    /// (obtained by handling a password-reset deep link).
    public func updatePassword(_ newPassword: String) async throws {
        do {
            try await client.auth.update(user: UserAttributes(password: newPassword))
            // isAwaitingPasswordReset is cleared inside handleEvent when .userUpdated fires.
        } catch {
            throw map(error)
        }
    }

    // MARK: - Account Management

    /// Updates the current user's email. Supabase sends a confirmation link to
    /// the new (and possibly old) address; the change takes effect on confirm.
    public func updateEmail(_ newEmail: String) async throws {
        let cleaned = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.auth.update(user: UserAttributes(email: cleaned))
        } catch {
            throw map(error)
        }
    }

    /// Updates the current user's username in both the `profiles` table and the
    /// auth user metadata. Throws `.usernameTaken` if another account owns it.
    public func updateUsername(_ newUsername: String) async throws {
        let cleaned = newUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let userID = currentUser?.id else {
            throw AuthError.sessionExpired
        }

        // Accounts from before `username` was in the metadata kept it in display_name.
        let currentUsername = currentUser?.username ?? currentUser?.displayName.lowercased()

        // Only enforce uniqueness if the username actually changed.
        if cleaned != currentUsername {
            let taken = try await isUsernameTaken(cleaned)
            if taken { throw AuthError.usernameTaken }
        }

        do {
            try await client.from("profiles")
                .update(["username": cleaned])
                .eq("id", value: userID)
                .execute()

            // Mirror the change into auth metadata; the resulting .userUpdated
            // event refreshes authState. A display name that was only ever a
            // copy of the old handle moves with it; a chosen one stays put.
            var data: [String: AnyJSON] = ["username": .string(cleaned)]
            if currentUser?.displayName.lowercased() == currentUsername {
                data["display_name"] = .string(cleaned)
            }
            try await client.auth.update(user: UserAttributes(data: data))
        } catch let authError as AuthError {
            throw authError
        } catch {
            throw map(error)
        }
    }

    public func updateDisplayName(_ newName: String) async throws {
        guard let user = currentUser else { throw AuthError.sessionExpired }
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        do {
            // Null, not "", when cleared: every client reads null as "use the username".
            try await client.from("profiles")
                .update(["display_name": trimmed.isEmpty ? nil : trimmed])
                .eq("id", value: user.id)
                .execute()
            try await client.auth.update(user: UserAttributes(data: [
                "display_name": .string(trimmed.isEmpty ? (user.username ?? user.displayName) : trimmed),
                "display_name_chosen": .bool(true)
            ]))
        } catch {
            throw map(error)
        }
    }

    // MARK: - Profile Picture

    private static let avatarsBucket = "avatars"

    /// Uploads image data to `avatars/<userID>/avatar.<ext>` (upsert) and returns
    /// the bucket's public URL. A cache-busting query item is appended so clients
    /// pick up a freshly-replaced avatar instead of a stale cached copy.
    public func uploadAvatar(_ data: Data, fileExtension: String) async throws -> URL {
        guard let userID = currentUser?.id else { throw AuthError.sessionExpired }

        let ext  = fileExtension.isEmpty ? "jpg" : fileExtension.lowercased()
        let path = "\(userID.uuidString.lowercased())/avatar.\(ext)"

        do {
            try await client.storage
                .from(Self.avatarsBucket)
                .upload(
                    path,
                    data: data,
                    options: FileOptions(contentType: Self.contentType(for: ext), upsert: true)
                )

            let publicURL = try client.storage
                .from(Self.avatarsBucket)
                .getPublicURL(path: path)

            // Cache-bust so the new image replaces the old one immediately.
            var comps = URLComponents(url: publicURL, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "v", value: String(Int(Date().timeIntervalSince1970)))]
            return comps?.url ?? publicURL
        } catch {
            throw map(error)
        }
    }

    /// Persists the avatar URL onto the `profiles` row and into auth metadata.
    /// Passing nil clears the avatar. The `.userUpdated` event refreshes authState.
    public func updateAvatarURL(_ url: URL?) async throws {
        guard let userID = currentUser?.id else { throw AuthError.sessionExpired }

        let value = url?.absoluteString
        do {
            try await client.from("profiles")
                .update(["avatar_url": value])
                .eq("id", value: userID)
                .execute()

            try await client.auth.update(user: UserAttributes(data: [
                "avatar_url": value.map(AnyJSON.string) ?? .null
            ]))
        } catch {
            throw map(error)
        }
    }

    /// Stores the chosen playlist sort order on the account. Silent on failure
    /// by design: the local choice has already taken effect, and a sort order
    /// is not worth an error dialog over a flaky network — the next change (or
    /// the next sign-in on this device) pushes it again.
    public func updatePlaylistSortOrder(_ raw: String) async {
        guard currentUser != nil else { return }
        try? await client.auth.update(user: UserAttributes(data: [
            "playlist_sort_order": .string(raw)
        ]))
    }

    /// Stores the per-playlist track sorts on the account. Silent on failure
    /// for the same reason as `updatePlaylistSortOrder`.
    public func updatePlaylistTrackSorts(_ raw: String) async {
        guard currentUser != nil else { return }
        try? await client.auth.update(user: UserAttributes(data: [
            "playlist_track_sorts": .string(raw)
        ]))
    }

    /// Stores the Spotify import ledger on the account. Silent on failure for
    /// the same reason as `updatePlaylistSortOrder`.
    public func updateSpotifyImports(_ raw: String) async {
        guard currentUser != nil else { return }
        try? await client.auth.update(user: UserAttributes(data: [
            "spotify_imports": .string(raw)
        ]))
    }

    /// Stores the saved albums on the account. Silent on failure, like the rest.
    public func updateSavedAlbums(_ raw: String) async {
        guard currentUser != nil else { return }
        try? await client.auth.update(user: UserAttributes(data: [
            "saved_albums": .string(raw)
        ]))
    }

    /// Stores the Spotify playlist links on the account. Silent on failure,
    /// like the rest.
    public func updateSpotifyLinks(_ raw: String) async {
        guard currentUser != nil else { return }
        try? await client.auth.update(user: UserAttributes(data: [
            "spotify_links": .string(raw)
        ]))
    }

    private static func contentType(for ext: String) -> String {
        switch ext {
        case "png":          return "image/png"
        case "heic":         return "image/heic"
        case "jpg", "jpeg":  return "image/jpeg"
        default:             return "image/jpeg"
        }
    }

    // MARK: - Discovery

    /// Prefix, case-insensitive username search against the (publicly-readable)
    /// `profiles` table. Excludes the current user from the results.
    public func searchUsers(matching query: String, limit: Int = 25) async throws -> [UserProfile] {
        // Commas and brackets are PostgREST's own syntax inside `or`.
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .filter { !",()\"".contains($0) }
        guard !cleaned.isEmpty else { return [] }

        // Escape LIKE wildcards so a literal % or _ in the query isn't treated as a pattern.
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        do {
            let rows: [UserProfile] = try await client.from("profiles")
                .select("id, username, display_name, avatar_url, created_at")
                .or("username.ilike.\(escaped)%,display_name.ilike.%\(escaped)%")
                .order("username", ascending: true)
                .limit(limit)
                .execute()
                .value

            let me = currentUser?.id
            return rows.filter { $0.id != me }
        } catch {
            throw map(error)
        }
    }

    public func fetchProfile(id: UUID) async throws -> UserProfile? {
        do {
            let rows: [UserProfile] = try await client.from("profiles")
                .select("id, username, display_name, avatar_url, created_at")
                .eq("id", value: id)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            throw map(error)
        }
    }

    /// Changes the password after re-authenticating with the current password.
    /// Separate from `updatePassword(_:)` (the reset-link recovery flow).
    public func changePassword(currentPassword: String, newPassword: String) async throws {
        guard newPassword.count >= 8 else { throw AuthError.weakPassword }

        guard let email = currentUser?.email, !email.isEmpty else {
            throw AuthError.sessionExpired
        }

        do {
            // Re-authenticate to verify the current password (throws if wrong).
            try await client.auth.signIn(email: email, password: currentPassword)
            try await client.auth.update(user: UserAttributes(password: newPassword))
        } catch {
            throw map(error)
        }
    }

    /// Handles a deep link URL opened by the OS (email confirmation or password reset).
    /// Calls supabase.auth.session(from:) which exchanges the URL tokens, fires an
    /// authStateChanges event, and updates authState automatically.
    public func handleDeepLink(_ url: URL) async {
        do {
            try await client.auth.session(from: url)
        } catch {
            print("[SupabaseAuthService] Deep link handling failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func makeUser(from session: Session) -> AppUser {
        let role: String? = {
            if case .string(let r) = session.user.userMetadata["role"] { return r }
            return nil
        }()
        let avatarURL: URL? = {
            if case .string(let raw) = session.user.userMetadata["avatar_url"], !raw.isEmpty {
                return URL(string: raw)
            }
            return nil
        }()
        let sortOrder: String? = {
            if case .string(let raw) = session.user.userMetadata["playlist_sort_order"], !raw.isEmpty {
                return raw
            }
            return nil
        }()
        let trackSorts: String? = {
            if case .string(let raw) = session.user.userMetadata["playlist_track_sorts"], !raw.isEmpty {
                return raw
            }
            return nil
        }()
        let spotifyImports: String? = {
            if case .string(let raw) = session.user.userMetadata["spotify_imports"], !raw.isEmpty {
                return raw
            }
            return nil
        }()
        let savedAlbums: String? = {
            if case .string(let raw) = session.user.userMetadata["saved_albums"], !raw.isEmpty { return raw }
            return nil
        }()
        let spotifyLinks: String? = {
            if case .string(let raw) = session.user.userMetadata["spotify_links"], !raw.isEmpty { return raw }
            return nil
        }()
        return AppUser(
            id:          session.user.id,
            email:       session.user.email ?? "",
            displayName: displayName(from: session),
            username:    {
                if case .string(let name) = session.user.userMetadata["username"], !name.isEmpty { return name }
                return nil
            }(),
            avatarURL:   avatarURL,
            role:        role,
            playlistSortOrder: sortOrder,
            playlistTrackSorts: trackSorts,
            spotifyImports: spotifyImports,
            savedAlbums: savedAlbums,
            spotifyLinks: spotifyLinks
        )
    }

    private func displayName(from session: Session) -> String {
        if case .string(let name) = session.user.userMetadata["display_name"], !name.isEmpty {
            return name
        }
        return Self.nameFromEmail(session.user.email ?? "")
    }

    private static func nameFromEmail(_ email: String) -> String {
        String(email.split(separator: "@").first ?? "Listener")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }

    private func map(_ error: Error) -> AuthError {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("invalid login") || msg.contains("invalid credentials") || msg.contains("invalid email or password") {
            return .invalidCredentials
        }
        if msg.contains("already registered") || msg.contains("already in use") || msg.contains("email taken") {
            return .emailAlreadyInUse
        }
        if msg.contains("network") || msg.contains("offline") || msg.contains("connection") {
            return .networkUnavailable
        }
        return .unknown(error.localizedDescription)
    }
}

// MARK: - OAuth callback repair

extension SupabaseAuthService {

    /// Rebuilds the OAuth callback into the shape the SDK expects.
    ///
    /// GoTrue does not always redirect to the `redirectTo` we asked for. When
    /// the project's redirect allow-list does not contain our scheme it falls
    /// back to the Site URL, and what comes back looks like this:
    ///
    ///     mixtape:?code=e322d496-2929-47b4-b416-002a140c49d8%23
    ///
    /// Two things are wrong. There is no `auth-callback` host, and `%23` — a
    /// `#` — is glued to the end of the code, because an empty fragment was
    /// appended to a URL with no path to hang it on and landed inside the
    /// query instead. `URLComponents` faithfully decodes that trailing hash as
    /// part of the value, so the SDK posts a code the server never issued and
    /// the exchange fails with `flow_state_not_found` — the code itself being
    /// perfectly valid one character earlier.
    ///
    /// So trim the code back to the credential and put the callback into
    /// canonical form. A well-formed callback passes through untouched.
    static func cleanedCallback(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return url }

        let strays = CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)
        let code = raw.trimmingCharacters(in: strays)
        guard code != raw || components.host != "auth-callback" else { return url }

        components.scheme   = "mixtape"
        components.host     = "auth-callback"
        components.path     = ""
        components.fragment = nil
        components.queryItems = components.queryItems?.map { item in
            item.name == "code" ? URLQueryItem(name: "code", value: code) : item
        }
        return components.url ?? url
    }
}

// MARK: - OAuth Presentation Anchor

/// Supplies the window the OAuth sheet is presented from.
///
/// See the note in `signInWithGoogle()`: the SDK's default anchor is an
/// unattached window, which iOS refuses to present from.
@MainActor
private final class OAuthPresentationAnchorProvider: NSObject,
                                                     ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let anchor = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
            return anchor ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// `ASWebAuthenticationSession` promises a URL or an error; this covers the
/// case its contract says cannot happen, so the continuation can never leak.
private struct AuthErrorMissingCallback: LocalizedError {
    var errorDescription: String? { "Sign-in returned no result." }
}
