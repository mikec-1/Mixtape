// MockAuthService.swift
// Mixtape — Core Services
//
// In-memory auth service for tests and previews — any email + password
// (min 8 chars) succeeds, no network calls.
// Session is persisted to UserDefaults so the user stays logged in across launches.

import Foundation
import Combine

@MainActor
public final class MockAuthService: ObservableObject, AuthServiceProtocol {

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let email       = "mix.mock.email"
        static let displayName = "mix.mock.displayName"
    }

    // MARK: - Published State

    @Published private(set) public var authState: AuthState = .loading

    // MARK: - Protocol Conformance

    public var authStatePublisher: AnyPublisher<AuthState, Never> {
        $authState.eraseToAnyPublisher()
    }

    public var currentUser: AppUser? {
        if case .authenticated(let user) = authState { return user }
        return nil
    }

    public var accessToken: String? { nil }

    // MARK: - In-Memory Credentials

    /// Last password used to sign in / sign up. Lets changePassword() validate
    /// the supplied current password in the mock.
    private var storedPassword: String?

    // MARK: - Init

    public init() {}

    // MARK: - Session Restore

    public func restoreSession() async {
        try? await Task.sleep(for: .milliseconds(300))
        if let email = UserDefaults.standard.string(forKey: Keys.email),
           let name  = UserDefaults.standard.string(forKey: Keys.displayName) {
            authState = .authenticated(AppUser(email: email, displayName: name))
        } else {
            authState = .unauthenticated
        }
    }

    // MARK: - Actions

    public func signIn(email: String, password: String) async throws {
        guard password.count >= 8 else { throw AuthError.weakPassword }
        try await Task.sleep(for: .seconds(1))
        let user = AppUser(email: email, displayName: Self.displayName(from: email))
        storedPassword = password
        persist(user)
        authState = .authenticated(user)
    }

    public func isUsernameTaken(_ username: String) async throws -> Bool {
        return false
    }

    @discardableResult
    public func signUp(email: String, password: String, username: String) async throws -> Bool {
        guard password.count >= 8 else { throw AuthError.weakPassword }
        try await Task.sleep(for: .seconds(1))
        let user = AppUser(
            email: email,
            displayName: username.isEmpty ? Self.displayName(from: email) : username
        )
        storedPassword = password
        persist(user)
        authState = .authenticated(user)
        return false   // mock: no email confirmation required
    }

    public func resetPassword(email: String) async throws {
        try await Task.sleep(for: .seconds(1))
        // Mock: always succeeds silently
    }

    public func signOut() async throws {
        try await Task.sleep(for: .milliseconds(300))
        storedPassword = nil
        clearPersisted()
        authState = .unauthenticated
    }

    // MARK: - Account Management

    public func updateEmail(_ newEmail: String) async throws {
        let cleaned = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.contains("@"), cleaned.contains(".") else {
            throw AuthError.unknown("Please enter a valid email address.")
        }
        guard var user = currentUser else { throw AuthError.sessionExpired }
        try await Task.sleep(for: .milliseconds(500))
        user.email = cleaned
        persist(user)
        authState = .authenticated(user)
    }

    public func updateUsername(_ newUsername: String) async throws {
        let cleaned = newUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else {
            throw AuthError.unknown("Username cannot be empty.")
        }
        guard var user = currentUser else { throw AuthError.sessionExpired }
        if cleaned != user.displayName.lowercased() {
            if try await isUsernameTaken(cleaned) { throw AuthError.usernameTaken }
        }
        try await Task.sleep(for: .milliseconds(500))
        user.displayName = cleaned
        persist(user)
        authState = .authenticated(user)
    }

    public func changePassword(currentPassword: String, newPassword: String) async throws {
        guard newPassword.count >= 8 else { throw AuthError.weakPassword }
        if let stored = storedPassword, stored != currentPassword {
            throw AuthError.invalidCredentials
        }
        try await Task.sleep(for: .milliseconds(500))
        storedPassword = newPassword
    }

    // MARK: - Profile Picture

    /// Mock: writes the image to a temp file and returns a `file://` URL so the
    /// avatar actually renders in previews without a network round-trip.
    public func uploadAvatar(_ data: Data, fileExtension: String) async throws -> URL {
        try await Task.sleep(for: .milliseconds(300))
        let ext = fileExtension.isEmpty ? "jpg" : fileExtension
        let url = URL.temporaryDirectory.appending(path: "mock-avatar-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    public func updateAvatarURL(_ url: URL?) async throws {
        guard var user = currentUser else { throw AuthError.sessionExpired }
        try await Task.sleep(for: .milliseconds(200))
        user.avatarURL = url
        persist(user)
        authState = .authenticated(user)
    }

    // MARK: - Discovery

    public func searchUsers(matching query: String, limit: Int) async throws -> [UserProfile] {
        try await Task.sleep(for: .milliseconds(300))
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return [] }
        #if DEBUG
        return UserProfile.previews
            .filter { $0.username.lowercased().hasPrefix(cleaned) }
            .prefix(limit)
            .map { $0 }
        #else
        return []
        #endif
    }

    public func fetchProfile(id: UUID) async throws -> UserProfile? {
        #if DEBUG
        return UserProfile.previews.first { $0.id == id }
        #else
        return nil
        #endif
    }

    // MARK: - Persistence

    private func persist(_ user: AppUser) {
        UserDefaults.standard.set(user.email,       forKey: Keys.email)
        UserDefaults.standard.set(user.displayName, forKey: Keys.displayName)
    }

    private func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: Keys.email)
        UserDefaults.standard.removeObject(forKey: Keys.displayName)
    }

    // MARK: - Helpers

    private static func displayName(from email: String) -> String {
        String(email.split(separator: "@").first ?? "Listener")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }
}
