// AuthViewModel.swift
// Mixtape — Features/Auth

import Foundation
import SwiftUI
import Combine
import AuthenticationServices

@MainActor
public final class AuthViewModel: ObservableObject {

    // MARK: - Form State

    @Published public var email: String = ""
    @Published public var password: String = ""
    @Published public var username: String = ""
    @Published public var isSignUpMode: Bool = false

    // MARK: - Async State

    @Published public private(set) var isLoading: Bool = false
    @Published public var errorMessage: String?
    @Published public var showError: Bool = false

    /// True while an Apple / Google sign-in is in flight (separate spinner from `isLoading`).
    @Published public private(set) var isSocialLoading: Bool = false

    // MARK: - Forgot Password State

    @Published public var showForgotPassword: Bool = false
    @Published public var resetEmail: String = ""
    @Published public private(set) var isResettingPassword: Bool = false
    @Published public var resetEmailSent: Bool = false

    // MARK: - Email Confirmation State

    /// True after signUp() when Supabase requires the user to click a confirmation email.
    /// Observed by MacAuthFlowView / SignInView to show the "check your email" screen.
    @Published public var showCheckEmail: Bool = false

    // MARK: - Set New Password State (for password-reset deep link)

    @Published public var newPassword: String = ""
    @Published public var confirmNewPassword: String = ""
    @Published public private(set) var isUpdatingPassword: Bool = false

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
        let usernameOK = !isSignUpMode || (!username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && usernameError == nil)
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
        print("[AuthViewModel] submit called. isSignUpMode: \(isSignUpMode), isFormValid: \(isFormValid)")
        guard isFormValid else {
            print("[AuthViewModel] Form validation failed.")
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if isSignUpMode {
                let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                print("[AuthViewModel] Registering. Cleaned username: '\(cleanUsername)'")
                // Check if username is taken
                let isTaken = try await authService.isUsernameTaken(cleanUsername)
                print("[AuthViewModel] Username '\(cleanUsername)' isTaken: \(isTaken)")
                if isTaken {
                    errorMessage = "Username is already taken."
                    showError = true
                    print("[AuthViewModel] Aborting signup: username is taken.")
                    return
                }

                let requiresConfirmation = try await authService.signUp(
                    email:       email,
                    password:    password,
                    username:    cleanUsername
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

    /// Completes a password reset. Called from SetNewPasswordSheet after the user
    /// has clicked a reset link and set their new password.
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

    /// Signs out the current user. Used by the Set New Password screen's Cancel action
    /// to destroy the recovery session when the user changes their mind.
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
            // ASWebAuthenticationSession cancellation surfaces as a CANCELED error — ignore it.
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            errorMessage = error.localizedDescription
            showError    = true
        }
    }

    public func toggleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSignUpMode.toggle()
            errorMessage = nil
            password = ""
        }
    }
}
