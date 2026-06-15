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
        return AppUser(
            id:          session.user.id,
            email:       session.user.email ?? "",
            displayName: displayName(from: session),
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
