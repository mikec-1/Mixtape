import Foundation
import SwiftUI
import Combine
import AuthenticationServices
import OSLog
import Observation

@Observable
@MainActor
public final class AuthViewModel {

    // MARK: - Form State

    public var email: String = ""
    public var password: String = ""
    public var username: String = ""
    /// Free-form, no format or availability check.
    public var displayName: String = ""
    public var isSignUpMode: Bool = false

    // MARK: - Async State

    public private(set) var isLoading: Bool = false
    public var errorMessage: String?
    public var showError: Bool = false

    /// Apple/Google sign-in in flight (separate spinner from `isLoading`).
    public private(set) var isSocialLoading: Bool = false

    // MARK: - Forgot Password State

    public var showForgotPassword: Bool = false
    public var resetEmail: String = ""
    public private(set) var isResettingPassword: Bool = false
    public var resetEmailSent: Bool = false

    // MARK: - Email Confirmation State

    /// Set after signUp() when the user must confirm by email. Shows the "check your email" screen.
    public var showCheckEmail: Bool = false

    // MARK: - Set New Password State (for password-reset deep link)

    public var newPassword: String = ""
    public var confirmNewPassword: String = ""
    public private(set) var isUpdatingPassword: Bool = false

    public var newPasswordError: String? {
        guard !newPassword.isEmpty else { return nil }
        return newPassword.count >= 8 ? nil : "At least 8 characters required."
    }

    public var confirmPasswordError: String? {
        guard !confirmNewPassword.isEmpty else { return nil }
        return newPassword == confirmNewPassword ? nil : "Passwords don't match."
    }

    public var isNewPasswordValid: Bool {
        newPassword.count >= 8 && newPassword == confirmNewPassword
    }

    // MARK: - Validation

    public var isFormValid: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        let passwordOK = password.count >= 8
        let usernameOK = !isSignUpMode || (!username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && usernameError == nil
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return emailOK && passwordOK && usernameOK
    }

    public var emailError: String? {
        guard !email.isEmpty else { return nil }
        return (email.contains("@") && email.contains(".")) ? nil : "Enter a valid email address."
    }

    public var passwordError: String? {
        guard !password.isEmpty else { return nil }
        return password.count >= 8 ? nil : "At least 8 characters required."
    }

    public var usernameError: String? {
        guard !username.isEmpty else { return nil }
        if username.count < 3 {
            return "At least 3 characters required."
        }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if username.unicodeScalars.contains(where: { !allowedCharacters.contains($0) }) {
            return "Letters, numbers, and underscores only."
        }
        return nil
    }

    // MARK: - Dependencies

    private let authService: SupabaseAuthService

    public init(authService: SupabaseAuthService) {
        self.authService = authService
    }

    // MARK: - Actions

    public func submit() async {
        MixLog.auth.debug("[AuthViewModel] submit called. isSignUpMode: \(self.isSignUpMode), isFormValid: \(self.isFormValid)")
        guard isFormValid else {
            MixLog.auth.debug("[AuthViewModel] Form validation failed.")
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if isSignUpMode {
                let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                MixLog.auth.debug("[AuthViewModel] Registering. Cleaned username: '\(cleanUsername)'")
                // Check if username is taken
                let isTaken = try await authService.isUsernameTaken(cleanUsername)
                MixLog.auth.debug("[AuthViewModel] Username '\(cleanUsername)' isTaken: \(isTaken)")
                if isTaken {
                    errorMessage = "Username is already taken."
                    showError = true
                    MixLog.auth.debug("[AuthViewModel] Aborting signup: username is taken.")
                    return
                }

                let requiresConfirmation = try await authService.signUp(
                    email:       email,
                    password:    password,
                    username:    cleanUsername,
                    displayName: displayName
                )
                if requiresConfirmation {
                    showCheckEmail = true
                }
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch let error as AuthError {
            errorMessage = error.errorDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    public func sendPasswordReset() async {
        let address = resetEmail.isEmpty ? email : resetEmail
        isResettingPassword = true
        defer { isResettingPassword = false }
        do {
            try await authService.resetPassword(email: address)
            resetEmailSent = true
        } catch let error as AuthError {
            errorMessage = error.errorDescription
            showError    = true
        } catch {
            errorMessage = error.localizedDescription
            showError    = true
        }
    }

    /// Re-sends the confirmation email for the current signup address.
    public func resendConfirmationEmail() async {
        guard !email.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.resendConfirmation(email: email)
        } catch let error as AuthError {
            errorMessage = error.errorDescription
            showError    = true
        } catch {
            errorMessage = error.localizedDescription
            showError    = true
        }
    }

    /// Completes a password reset from SetNewPasswordSheet.
    public func updatePassword() async {
        guard isNewPasswordValid else { return }
        isUpdatingPassword = true
        defer { isUpdatingPassword = false }
        do {
            try await authService.updatePassword(newPassword)
            newPassword        = ""
            confirmNewPassword = ""
        } catch let error as AuthError {
            errorMessage = error.errorDescription
            showError    = true
        } catch {
            errorMessage = error.localizedDescription
            showError    = true
        }
    }

    /// Signs out. Used by Set New Password's Cancel to drop the recovery session.
    public func signOut() async {
        do { try await authService.signOut() } catch {}
    }

    // MARK: - Social Sign-In

    /// Starts the Google OAuth flow (system browser sheet).
    public func signInWithGoogle() async {
        isSocialLoading = true
        defer { isSocialLoading = false }
        do {
            try await authService.signInWithGoogle()
        } catch let error as AuthError {
            errorMessage = error.errorDescription
            showError    = true
        } catch {
            // User cancelled the web sheet.
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            errorMessage = error.localizedDescription
            showError    = true
        }
    }

    public func toggleMode() {
        withMixAnimation(.easeInOut(duration: 0.2)) {
            isSignUpMode.toggle()
            errorMessage = nil
            password = ""
        }
    }
}
