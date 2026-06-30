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

@MainActor
public final class SupabaseAuthService: ObservableObject, AuthServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var authState: AuthState = .loading

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

    private let client: SupabaseClient
    private var listenerTask: Task<Void, Never>?

    /// Continuation used by restoreSession() to wait for the first SDK event.
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    private var didReceiveInitialEvent = false

    // MARK: - Init

    public init(client: SupabaseClient) {
        self.client = client
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
            accessToken = nil
            authState = .unauthenticated
            isAwaitingPasswordReset = false
            pendingEmailConfirmation = false
            pendingUsernameSelection = false
            suggestedUsername = nil

        default:
            // .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified …
            if let session {
                accessToken = session.accessToken
                pendingEmailConfirmation = false        // confirmed (or confirmation not required)
                if event == .userUpdated {
                    // Password update complete — clear the gate and admit the user.
                    isAwaitingPasswordReset = false
                    authState = .authenticated(makeUser(from: session))
                } else if !isAwaitingPasswordReset {
                    authState = .authenticated(makeUser(from: session))
                }
                // If isAwaitingPasswordReset is still true (a follow-on token event fired
                // after .passwordRecovery), we deliberately do NOT authenticate —
                // the user must set a new password before entering the app.
            } else if !isAwaitingPasswordReset {
                // Don't wipe auth state while waiting for password update
                accessToken = nil
                authState = .unauthenticated
            }
        }

        // Resume restoreSession() on the first SDK event regardless of type.
        if !didReceiveInitialEvent {
            didReceiveInitialEvent = true
            restoreContinuation?.resume()
            restoreContinuation = nil
        }
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
                        self.authState = .unauthenticated
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

    /// Signs in with Google via the SDK's built-in OAuth flow. This presents an
    /// `ASWebAuthenticationSession` (a system browser sheet inside the app) and
    /// returns through the `mixtape://` redirect — no extra SDK dependency.
    public func signInWithGoogle() async throws {
        do {
            try await client.auth.signInWithOAuth(
                provider:   .google,
                redirectTo: URL(string: "mixtape://auth-callback")
            ) { (session: ASWebAuthenticationSession) in
                // Keep the web session so returning Google users skip re-consent.
                session.prefersEphemeralWebBrowserSession = false
            }
            await checkUsernamePrompt()
        } catch {
            throw map(error)
        }
    }

    /// After a social sign-in, raises `pendingUsernameSelection` unless the user
    /// has already completed the prompt once (tracked by a `username_chosen` flag
    /// in their auth metadata). Deterministic — doesn't depend on guessing the
    /// trigger-assigned username. Best-effort; failures are silently ignored.
    private func checkUsernamePrompt() async {
        let metadata = client.auth.currentUser?.userMetadata ?? [:]

        // Already chosen (or explicitly skipped) — don't nag again.
        if case .bool(true)? = metadata["username_chosen"] { return }

        // Pre-fill a suggestion from the provider's name, if any.
        let nameKeys = ["full_name", "name", "display_name"]
        for key in nameKeys {
            if case .string(let raw)? = metadata[key] {
                let cleaned = raw
                    .lowercased()
                    .unicodeScalars
                    .filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }
                    .map(String.init)
                    .joined()
                if !cleaned.isEmpty { suggestedUsername = cleaned; break }
            }
        }

        pendingUsernameSelection = true
    }

    /// Completes a social sign-up: sets the chosen username and, optionally, a
    /// password so the user can also sign in with email next time. The account
    /// already has a verified email (from Google), so attaching a password simply
    /// adds an email/password credential to the same account. Then clears the prompt.
    public func chooseUsername(_ name: String, password: String? = nil) async throws {
        try await updateUsername(name)
        do {
            if let password, !password.isEmpty {
                guard password.count >= 8 else { throw AuthError.weakPassword }
                try await client.auth.update(user: UserAttributes(password: password))
            }
            // Mark the prompt as completed so it never shows again.
            try await client.auth.update(user: UserAttributes(data: ["username_chosen": .bool(true)]))
        } catch let error as AuthError {
            throw error
        } catch {
            throw map(error)
        }
        pendingUsernameSelection = false
        suggestedUsername = nil
    }

    /// Dismisses the username prompt (Skip / swipe-down) and remembers the choice so
    /// it isn't shown again, keeping the auto-assigned username.
    public func dismissUsernamePrompt() {
        Task { try? await client.auth.update(user: UserAttributes(data: ["username_chosen": .bool(true)])) }
        pendingUsernameSelection = false
        suggestedUsername = nil
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
    public func signUp(email: String, password: String, username: String) async throws -> Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let response = try await client.auth.signUp(
                email:    email,
                password: password,
                data:     [
                    "username": AnyJSON.string(cleanUsername),
                    "display_name": AnyJSON.string(cleanUsername)
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

    public func signOut() async throws {
        do {
            try await client.auth.signOut()
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

        let currentUsername = currentUser?.displayName.lowercased()

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

            // Mirror the change into auth metadata so display_name/username refresh.
            // The resulting .userUpdated event refreshes authState automatically.
            try await client.auth.update(user: UserAttributes(data: [
                "username": .string(cleaned),
                "display_name": .string(cleaned)
            ]))
        } catch let authError as AuthError {
            throw authError
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
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return [] }

        // Escape LIKE wildcards so a literal % or _ in the query isn't treated as a pattern.
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        do {
            let rows: [UserProfile] = try await client.from("profiles")
                .select("id, username, avatar_url, created_at")
                .ilike("username", pattern: "\(escaped)%")
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
                .select("id, username, avatar_url, created_at")
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
        return AppUser(
            id:          session.user.id,
            email:       session.user.email ?? "",
            displayName: displayName(from: session),
            avatarURL:   avatarURL,
            role:        role
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
