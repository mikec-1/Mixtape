// Auth service backed by Supabase. The SDK keeps the refresh token in the Keychain
// and refreshes JWTs; this observes authStateChanges.

import Foundation
import Supabase
import Combine
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import OSLog

@MainActor
public final class SupabaseAuthService: ObservableObject, AuthServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var authState: AuthState = .loading {
        didSet {
            // Scope EQ to the signed-in user so settings don't leak between accounts.
            if case .authenticated(let user) = authState {
                AudioEqualizer.currentUserID = user.id.uuidString
                // Account-wide preferences follow the user across devices.
                PlaylistSortSyncService.shared.adoptRemote(user.playlistSortOrder)
                PlaylistTrackSortService.shared.adoptRemote(user.playlistTrackSorts)
                PlaylistTransitionService.shared.adoptRemote(user.playlistTransitions)
                SpotifyImportLedger.shared?.adoptRemote(user.spotifyImports)
                SavedAlbumsService.shared.adoptRemote(user.savedAlbums)
                CrateService.shared.adoptRemote(user.crates)
                ThemeManager.shared.adoptRemoteBackdrop(user.backdrop)
                SpotifyFollowService.shared?.adoptRemote(user.spotifyLinks)
                PlaylistMetadataService.shared.adoptRemoteShowsAllSongs(user.showsAllSongs)
                PlaylistMetadataService.shared.adoptRemoteImportDestination(user.importsTo)
                Analytics.adoptRemote(user.analyticsOptIn)
            } else {
                AudioEqualizer.currentUserID = nil
            }
        }
    }

    /// Running on a cached session because the token couldn't be refreshed. Still signed in,
    /// just no server to confirm with. See `enterOffline`.
    @Published private(set) public var isOffline: Bool = false

    /// Set by a password-reset link. The session is live for updatePassword, but authState
    /// stays .unauthenticated until the new password is set.
    @Published public private(set) var isAwaitingPasswordReset: Bool = false

    /// Set after signUp() when email confirmation is required. Cleared by the confirmation link.
    @Published public private(set) var pendingEmailConfirmation: Bool = false

    /// Set after a social sign-in while the user still has the trigger's `user_xxxxxxxx`
    /// username. RootView shows a one-time, skippable prompt.
    @Published public private(set) var pendingUsernameSelection: Bool = false

    /// Username suggestion from the provider profile, or nil.
    public private(set) var suggestedUsername: String?
    /// The provider's name as given ("Mike Smith"), to pre-fill the display name.
    public private(set) var suggestedDisplayName: String?
    /// Asks only for a display name (older accounts that already have a real username).
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

    // Building the client is slow, so it's created on first use instead of at launch.
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
            // Keep the session for updatePassword() but stay .unauthenticated so RootView doesn't enter the app.
            accessToken = session?.accessToken
            isAwaitingPasswordReset = true
            authState = .unauthenticated

        case .signedOut:
            // The only event that means signed out. A missing session elsewhere means "couldn't ask".
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
            if let session {
                accessToken = session.accessToken
                isOffline = false
                cache(makeUser(from: session))
                pendingEmailConfirmation = false        // confirmed (or confirmation not required)
                if event == .userUpdated {
                    // Password updated, admit the user.
                    isAwaitingPasswordReset = false
                    authState = .authenticated(makeUser(from: session))
                } else if !isAwaitingPasswordReset {
                    authState = .authenticated(makeUser(from: session))
                    if event == .initialSession || event == .signedIn {
                        Task { await checkDisplayNamePrompt() }
                    }
                }
                // A token event after .passwordRecovery must not authenticate before the password is set.
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
    /// How long a device may run on a cached session before going back online.
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

    /// Enters the app on the last known user when the token couldn't be refreshed.
    /// False (show login) when there's no cached user or the grace period is up.
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

    /// Called when the network returns; the SDK's refresh timer may not retry on its own.
    /// Success arrives as `.tokenRefreshed` and clears `isOffline`.
    public func retryOnlineAuth() async {
        guard isOffline else { return }
        _ = try? await client.auth.refreshSession()
    }

    // MARK: - Session Restore

    /// Waits up to 5s for the SDK's initial auth event.
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

    /// Signs in with Google via `launchFlow`, to supply our own presentation anchor (the SDK's
    /// default can't present on iOS) and clean the callback before it's exchanged.
    /// The session isn't ephemeral so Google's account chooser and the signed-in browser are used.
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
            MixLog.auth.error("Google sign-in failed: \(error), \(error.localizedDescription)")
            throw map(error)
        }
    }

    /// Google overwrites `avatar_url` in auth metadata on each sign-in. If the user uploaded
    /// one to `profiles.avatar_url`, write it back. Best-effort.
    private func reconcileProfileAvatar() async {
        guard let userID = client.auth.currentUser?.id,
              let custom = try? await fetchProfileAvatarURL(userID: userID),
              !custom.isEmpty else { return }

        let currentMeta: String? = {
            if case .string(let raw)? = client.auth.currentUser?.userMetadata["avatar_url"] { return raw }
            return nil
        }()
        guard currentMeta != custom else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: ["avatar_url": .string(custom)]))
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

    /// After a social sign-in, raises `pendingUsernameSelection` unless `username_chosen`
    /// is set in auth metadata. Best-effort.
    private func checkUsernamePrompt() async {
        let metadata = client.auth.currentUser?.userMetadata ?? [:]

        if case .bool(true)? = metadata["username_chosen"] { return }

        // Email accounts later signed in with Google have a real username but no flag.
        // Treat those as chosen and write the flag.
        if let userID = client.auth.currentUser?.id,
           let existing = try? await fetchProfileUsername(userID: userID),
           !isAutoGeneratedUsername(existing) {
            _ = try? await client.auth.update(user: UserAttributes(data: ["username_chosen": .bool(true)]))
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

    /// Once per account: asks users with a username but no display name for one.
    /// Saving or skipping writes `display_name_chosen`.
    private func checkDisplayNamePrompt() async {
        guard !checkedDisplayName, !pendingUsernameSelection,
              let userID = client.auth.currentUser?.id else { return }
        checkedDisplayName = true
        if case .bool(true)? = client.auth.currentUser?.userMetadata["display_name_chosen"] { return }
        // A placeholder username is the full prompt's job (checkUsernamePrompt).
        guard let profile = try? await fetchProfile(id: userID),
              !isAutoGeneratedUsername(profile.username) else { return }
        if profile.displayName != nil {
            _ = try? await client.auth.update(user: UserAttributes(data: ["display_name_chosen": .bool(true)]))
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

    /// The trigger's placeholder username (`user_` + 8 hex chars).
    private func isAutoGeneratedUsername(_ name: String) -> Bool {
        name.range(of: "^user_[0-9a-f]{8}$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Finishes a social sign-up: sets the username and optionally a password for email sign-in.
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

    /// Skips the username prompt for good, keeping the auto-assigned username.
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
        MixLog.auth.debug("[SupabaseAuthService] Checking if username '\(cleaned)' is taken...")
        do {
            let response: [ProfileCheck] = try await client.from("profiles")
                .select("id")
                .eq("username", value: cleaned)
                .limit(1)
                .execute()
                .value
            let taken = !response.isEmpty
            MixLog.auth.debug("[SupabaseAuthService] Username '\(cleaned)' taken check result: \(taken) (found \(response.count) rows)")
            return taken
        } catch {
            MixLog.auth.error("[SupabaseAuthService] isUsernameTaken error for '\(cleaned)': \(error)")
            throw error
        }
    }

    /// Returns `true` when email confirmation is required before the session is active.
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
            // No session means email confirmation is enabled.
            let requiresConfirmation = (response.session == nil)
            if requiresConfirmation {
                pendingEmailConfirmation = true
            }
            return requiresConfirmation
        } catch {
            throw map(error)
        }
    }

    /// This device only unless `everywhere`. The SDK defaults to global.
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

    /// Needs a live recovery session from a password-reset link.
    public func updatePassword(_ newPassword: String) async throws {
        do {
            try await client.auth.update(user: UserAttributes(password: newPassword))
            // isAwaitingPasswordReset is cleared inside handleEvent when .userUpdated fires.
        } catch {
            throw map(error)
        }
    }

    // MARK: - Account Management

    /// Supabase emails a confirmation link; the change applies on confirm.
    public func updateEmail(_ newEmail: String) async throws {
        let cleaned = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.auth.update(user: UserAttributes(email: cleaned))
        } catch {
            throw map(error)
        }
    }

    /// Updates the username in `profiles` and auth metadata. Throws `.usernameTaken` if it's in use.
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

            // A display name that was just a copy of the old handle moves with it.
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

    /// Uploads to `avatars/<userID>/avatar.<ext>` and returns the public URL with a cache-buster.
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

    /// Saves the avatar URL to `profiles` and auth metadata. Nil clears it.
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

    /// Saves the playlist sort order on the account. Silent on failure; the next change pushes again.
    public func updatePlaylistSortOrder(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "playlist_sort_order": .string(raw)
        ]))
    }

    /// Per-playlist track sorts. Silent on failure.
    public func updatePlaylistTrackSorts(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "playlist_track_sorts": .string(raw)
        ]))
    }

    /// Per-playlist transitions. Silent on failure.
    public func updatePlaylistTransitions(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "playlist_transitions": .string(raw)
        ]))
    }

    /// Spotify import ledger. Silent on failure.
    public func updateSpotifyImports(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "spotify_imports": .string(raw)
        ]))
    }

    /// Stores the saved albums on the account. Silent on failure, like the rest.
    public func updateSavedAlbums(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "saved_albums": .string(raw)
        ]))
    }

    /// Background colour. Silent on failure.
    public func updateBackdrop(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "backdrop": .string(raw)
        ]))
    }

    /// Crates. Silent on failure.
    public func updateCrates(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "crates": .string(raw)
        ]))
    }

    /// Show All Songs. Silent on failure.
    public func updateShowsAllSongs(_ on: Bool) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "show_all_songs": .bool(on)
        ]))
    }

    /// Where imported songs go. Silent on failure.
    public func updateImportDestination(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "imports_to": .string(raw)
        ]))
    }

    /// Help Improve Mixtape. Silent on failure.
    public func updateAnalyticsOptIn(_ on: Bool) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
            "analytics_opt_in": .bool(on)
        ]))
    }

    /// Spotify playlist links. Silent on failure.
    public func updateSpotifyLinks(_ raw: String) async {
        guard currentUser != nil else { return }
        _ = try? await client.auth.update(user: UserAttributes(data: [
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

    /// Case-insensitive username prefix search on `profiles`, excluding the current user.
    public func searchUsers(matching query: String, limit: Int = 25) async throws -> [UserProfile] {
        // Commas and brackets are PostgREST's own syntax inside `or`.
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .filter { !",()\"".contains($0) }
        guard !cleaned.isEmpty else { return [] }

        // Escape LIKE wildcards.
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

    /// Re-authenticates first. `updatePassword(_:)` is the reset-link flow.
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

    /// Handles an email confirmation or password-reset deep link. The resulting
    /// authStateChanges event updates authState.
    public func handleDeepLink(_ url: URL) async {
        do {
            try await client.auth.session(from: url)
        } catch {
            MixLog.auth.error("[SupabaseAuthService] Deep link handling failed: \(error.localizedDescription)")
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
        let crates: String? = {
            if case .string(let raw) = session.user.userMetadata["crates"], !raw.isEmpty { return raw }
            return nil
        }()
        let spotifyLinks: String? = {
            if case .string(let raw) = session.user.userMetadata["spotify_links"], !raw.isEmpty { return raw }
            return nil
        }()
        let backdrop: String? = {
            if case .string(let raw) = session.user.userMetadata["backdrop"], !raw.isEmpty { return raw }
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
            playlistTransitions: {
                if case .string(let raw) = session.user.userMetadata["playlist_transitions"], !raw.isEmpty { return raw }
                return nil
            }(),
            spotifyImports: spotifyImports,
            savedAlbums: savedAlbums,
            crates: crates,
            spotifyLinks: spotifyLinks,
            backdrop: backdrop,
            showsAllSongs: {
                if case .bool(let on) = session.user.userMetadata["show_all_songs"] { return on }
                return nil
            }(),
            importsTo: {
                if case .string(let raw) = session.user.userMetadata["imports_to"] { return raw }
                return nil
            }(),
            analyticsOptIn: {
                if case .bool(let on) = session.user.userMetadata["analytics_opt_in"] { return on }
                return nil
            }()
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

    /// Normalises the OAuth callback. When GoTrue falls back to the Site URL it returns
    /// `mixtape:?code=...%23`: no `auth-callback` host and a `#` glued to the code, which
    /// fails with `flow_state_not_found`. Well-formed callbacks pass through.
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

/// Window the OAuth sheet is presented from. iOS won't present from the SDK's default.
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

/// Covers the "no URL and no error" case so the continuation never leaks.
private struct AuthErrorMissingCallback: LocalizedError {
    var errorDescription: String? { "Sign-in returned no result." }
}
