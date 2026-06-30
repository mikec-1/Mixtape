// AuthServiceProtocol.swift
// Mixtape — Core Protocols
//
// Implemented by MockAuthService and SupabaseAuthService.

import Foundation
import Combine

// MARK: - Auth State

public enum AuthState: Equatable {
    case loading
    case authenticated(AppUser)
    case unauthenticated
}

// MARK: - Auth Errors

public enum AuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyInUse
    case usernameTaken
    case weakPassword
    case networkUnavailable
    case sessionExpired
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:  return "Incorrect email or password."
        case .emailAlreadyInUse:   return "An account with that email already exists."
        case .usernameTaken:       return "That username is already taken. Try another."
        case .weakPassword:        return "Password must be at least 8 characters."
        case .networkUnavailable:  return "No internet connection. Try again when online."
        case .sessionExpired:      return "Your session has expired. Please sign in again."
        case .unknown(let msg):    return msg
        }
    }
}

// MARK: - Protocol

/// Describes the full authentication capability of the app.
/// Conformers must be `ObservableObject` — enforced by concrete types, not the protocol,
/// because Swift protocols can't directly inherit ObservableObject with Publishers.
public protocol AuthServiceProtocol: AnyObject {

    /// Current authentication state. Always reflects the latest known value.
    var authState: AuthState { get }

    /// Publisher that emits each time `authState` changes.
    /// Used by `AppDependencies` to reactively toggle root navigation.
    var authStatePublisher: AnyPublisher<AuthState, Never> { get }

    /// Convenience accessor for the currently signed-in user, or nil.
    var currentUser: AppUser? { get }

    /// JWT access token for attaching to Supabase API calls.
    /// `nil` when unauthenticated or when using the mock service.
    var accessToken: String? { get }

    // MARK: Actions

    func signIn(email: String, password: String) async throws
    func isUsernameTaken(_ username: String) async throws -> Bool
    /// Returns `true` when email confirmation is required before the user is signed in.
    @discardableResult
    func signUp(email: String, password: String, username: String) async throws -> Bool
    func signOut() async throws
    /// Send a password reset email. Throws if the address is unknown or network is unavailable.
    func resetPassword(email: String) async throws

    // MARK: Account Management

    /// Updates the current user's email address. Supabase typically sends a
    /// confirmation link to the new (and/or old) address; the change may only
    /// take effect once that link is confirmed.
    func updateEmail(_ newEmail: String) async throws

    /// Updates the current user's username (trimmed + lowercased). Throws
    /// `.usernameTaken` if the name is already in use by another account.
    /// Updates both the `profiles` table and the auth user metadata.
    func updateUsername(_ newUsername: String) async throws

    /// Changes the current user's password after re-authenticating with their
    /// current password. Distinct from the reset-link recovery flow
    /// (`updatePassword(_:)`). Throws `.invalidCredentials` if the current
    /// password is wrong, `.weakPassword` if the new password is too short.
    func changePassword(currentPassword: String, newPassword: String) async throws
    /// Attempt to restore a persisted session on app launch.
    func restoreSession() async

    // MARK: Profile Picture

    /// Uploads raw image data as the current user's avatar and returns the public
    /// URL. The image should already be downscaled/compressed by the caller.
    /// `fileExtension` is the lowercased extension without a dot (e.g. "jpg").
    /// Does NOT persist the URL onto the profile — call `updateAvatarURL(_:)` after.
    func uploadAvatar(_ data: Data, fileExtension: String) async throws -> URL

    /// Persists the avatar URL onto the user's `profiles` row and auth metadata.
    /// Pass `nil` to clear the avatar. The refreshed `AppUser` carries the change.
    func updateAvatarURL(_ url: URL?) async throws

    // MARK: Discovery

    /// Searches public profiles whose username matches `query` (prefix, case-
    /// insensitive). Returns up to `limit` results, excluding the current user.
    func searchUsers(matching query: String, limit: Int) async throws -> [UserProfile]

    /// Fetches a single public profile by its id, or nil if it doesn't exist.
    func fetchProfile(id: UUID) async throws -> UserProfile?
}
