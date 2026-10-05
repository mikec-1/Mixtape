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

/// The app's auth capability. Conformers are ObservableObject.
public protocol AuthServiceProtocol: AnyObject {

    /// Current authentication state. Always reflects the latest known value.
    var authState: AuthState { get }

    var authStatePublisher: AnyPublisher<AuthState, Never> { get }

    /// Convenience accessor for the currently signed-in user, or nil.
    var currentUser: AppUser? { get }

    /// Nil when signed out.
    var accessToken: String? { get }

    // MARK: Actions

    func signIn(email: String, password: String) async throws
    func isUsernameTaken(_ username: String) async throws -> Bool
    /// Returns `true` when email confirmation is required before the user is signed in.
    @discardableResult
    func signUp(email: String, password: String, username: String, displayName: String) async throws -> Bool
    func signOut(everywhere: Bool) async throws
    func resetPassword(email: String) async throws

    // MARK: Account Management

    /// Supabase may require confirming the link before it takes effect.
    func updateEmail(_ newEmail: String) async throws

    /// Trimmed and lowercased. Throws .usernameTaken.
    func updateUsername(_ newUsername: String) async throws

    /// Empty clears it and the username shows instead.
    func updateDisplayName(_ newName: String) async throws

    /// Re-authenticates first. Throws .invalidCredentials or .weakPassword.
    func changePassword(currentPassword: String, newPassword: String) async throws
    /// Attempt to restore a persisted session on app launch.
    func restoreSession() async

    // MARK: Profile Picture

    /// Uploads an already-compressed avatar and returns its URL.
    /// Call updateAvatarURL(_:) to save it.
    func uploadAvatar(_ data: Data, fileExtension: String) async throws -> URL

    /// Nil clears it.
    func updateAvatarURL(_ url: URL?) async throws

    // MARK: Discovery

    /// Username prefix or display name match, excluding the current user.
    func searchUsers(matching query: String, limit: Int) async throws -> [UserProfile]

    /// Fetches a single public profile by its id, or nil if it doesn't exist.
    func fetchProfile(id: UUID) async throws -> UserProfile?
}

public extension AuthServiceProtocol {
    /// This device only.
    func signOut() async throws { try await signOut(everywhere: false) }
}
