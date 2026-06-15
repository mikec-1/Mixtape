// SignInView.swift
// Mixtape — Features/Auth

import SwiftUI

public struct SignInView: View {

    @StateObject   private var vm:          AuthViewModel
    @ObservedObject private var authService: SupabaseAuthService

    public init(authService: SupabaseAuthService) {
        _vm          = StateObject(wrappedValue: AuthViewModel(authService: authService))
        _authService = ObservedObject(wrappedValue: authService)
    }

    public var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            if authService.isAwaitingPasswordReset {
                IOSSetNewPasswordView(vm: vm)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            } else if vm.showCheckEmail {
                CheckEmailView(vm: vm)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                authForm
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: authService.isAwaitingPasswordReset)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: vm.showCheckEmail)
        .alert("Sign In Error", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "An error occurred.")
        }
        .sheet(isPresented: $vm.showForgotPassword) {
            ForgotPasswordSheet(vm: vm)
        }
    }

    // MARK: - Auth Form

    private var authForm: some View {
        ScrollView {
            VStack(spacing: 0) {
                brandHeader
                    .padding(.top, 72)
                    .padding(.bottom, 48)

                formCard
                    .padding(.horizontal, 24)

                modeToggle
                    .padding(.top, 24)

                Spacer(minLength: 40)
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    // MARK: - Subviews

    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.mixPrimary.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.mixPrimary)
            }
            Text("Mixtape")
                .font(.mixDisplay)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Your music, everywhere.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
        }
    }

    private var formCard: some View {
        VStack(spacing: 16) {
            Text(vm.isSignUpMode ? "Create Account" : "Welcome Back")
                .font(.mixTitle)
                .foregroundStyle(Color.mixTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if vm.isSignUpMode {
                MixtapeTextField(
                    label: "Username",
                    placeholder: "Choose a username",
                    text: $vm.username,
                    icon: MixtapeIcons.account,
                    errorMessage: vm.usernameError
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            MixtapeTextField(
                label: "Email",
                placeholder: "you@example.com",
                text: $vm.email,
                icon: "envelope",
                isEmail: true,
                errorMessage: vm.emailError
            )

            MixtapeSecureField(
                label: "Password",
                placeholder: vm.isSignUpMode ? "Min. 8 characters" : "Password",
                text: $vm.password,
                errorMessage: vm.passwordError
            )

            if !vm.isSignUpMode {
                HStack {
                    Spacer()
                    Button("Forgot password?") {
                        vm.resetEmail = vm.email
                        vm.showForgotPassword = true
                    }
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixPrimary)
                }
                .padding(.top, -4)
            }

            Button {
                Task { await vm.submit() }
            } label: {
                Group {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    } else {
                        Text(vm.isSignUpMode ? "Create Account" : "Sign In")
                            .font(.mixButton)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 16)
                .background(vm.isFormValid ? Color.mixPrimary : Color.mixPrimary.opacity(0.4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!vm.isFormValid || vm.isLoading)
            .animation(.easeInOut(duration: 0.15), value: vm.isFormValid)
            .padding(.top, 8)
        }
        .padding(24)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var modeToggle: some View {
        Button(action: vm.toggleMode) {
            HStack(spacing: 4) {
                Text(vm.isSignUpMode ? "Already have an account?" : "Don't have an account?")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                Text(vm.isSignUpMode ? "Sign In" : "Create one")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixPrimary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Set New Password View (iOS, shown after password-reset deep link)

private struct IOSSetNewPasswordView: View {

    @ObservedObject var vm: AuthViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 60)

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.mixPrimary.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "lock.rotation")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.mixPrimary)
                }

                VStack(spacing: 10) {
                    Text("Set new password")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)

                    Text("Your identity has been verified.\nCreate a new password to continue.")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 14) {
                    MixtapeSecureField(
                        label:        "New password",
                        placeholder:  "Min. 8 characters",
                        text:         $vm.newPassword,
                        errorMessage: vm.newPasswordError
                    )
                    MixtapeSecureField(
                        label:        "Confirm password",
                        placeholder:  "Repeat new password",
                        text:         $vm.confirmNewPassword,
                        errorMessage: vm.confirmPasswordError
                    )
                }
                .padding(.horizontal, 24)

                Button {
                    Task { await vm.updatePassword() }
                } label: {
                    Group {
                        if vm.isUpdatingPassword {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 24)
                        } else {
                            Text("Set Password")
                                .font(.mixButton)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 16)
                    .background(vm.isNewPasswordValid ? Color.mixPrimary : Color.mixPrimary.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!vm.isNewPasswordValid || vm.isUpdatingPassword)
                .padding(.horizontal, 24)

                // Cancel — destroys the recovery session
                Button {
                    Task { await vm.signOut() }
                } label: {
                    Text("Cancel")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 40)
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

// MARK: - Check Email View (iOS)

private struct CheckEmailView: View {

    @ObservedObject var vm: AuthViewModel
    @State private var didResend = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 60)

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.mixPrimary.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.mixPrimary)
                }

                VStack(spacing: 10) {
                    Text("Check your inbox")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)

                    VStack(spacing: 4) {
                        Text("We sent a verification link to")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                        Text(vm.email)
                            .font(.mixBodyBold)
                            .foregroundStyle(Color.mixTextPrimary)
                    }
                    .multilineTextAlignment(.center)

                    Text("Tap the link in the email to activate your account. Once confirmed, open Mixtape and you'll be signed in automatically.")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)

                // Resend
                if didResend {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.mixPrimary)
                        Text("Email resent!")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                    .transition(.opacity)
                } else {
                    Button {
                        Task {
                            await vm.resendConfirmationEmail()
                            withAnimation { didResend = true }
                            Task {
                                try? await Task.sleep(for: .seconds(8))
                                withAnimation { didResend = false }
                            }
                        }
                    } label: {
                        Group {
                            if vm.isLoading {
                                ProgressView().tint(.white).frame(height: 24).frame(maxWidth: .infinity)
                            } else {
                                Text("Resend verification email")
                                    .font(.mixButton)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 16)
                        .background(Color.mixSurface)
                        .foregroundStyle(Color.mixPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.mixPrimary.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .disabled(vm.isLoading)
                    .padding(.horizontal, 24)
                }

                // Back to sign-in
                Button {
                    withAnimation { vm.showCheckEmail = false }
                } label: {
                    Text("← Back to sign in")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain)

                Text("Check your spam folder if you don't see it within a minute.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer(minLength: 40)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: didResend)
    }
}

// MARK: - Input Components

private struct MixtapeTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var isEmail: Bool = false
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)

            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextTertiary)
                        .frame(width: 20)
                }
                TextField(placeholder, text: $text)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(isEmail ? .emailAddress : .default)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            .padding(14)
            .background(Color.mixSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        errorMessage != nil ? Color.mixDestructive.opacity(0.6) : Color.mixSeparator,
                        lineWidth: 1
                    )
            )

            if let err = errorMessage {
                Text(err)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixDestructive)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: errorMessage)
    }
}

private struct MixtapeSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var errorMessage: String? = nil
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)

            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mixTextTertiary)
                    .frame(width: 20)

                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .padding(14)
            .background(Color.mixSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        errorMessage != nil ? Color.mixDestructive.opacity(0.6) : Color.mixSeparator,
                        lineWidth: 1
                    )
            )

            if let err = errorMessage {
                Text(err)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixDestructive)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: errorMessage)
    }
}

// MARK: - Forgot Password Sheet

private struct ForgotPasswordSheet: View {

    @ObservedObject var vm: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.mixPrimary.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.mixPrimary)
                    }

                    if vm.resetEmailSent {
                        VStack(spacing: 12) {
                            Text("Check your inbox")
                                .font(.mixTitle)
                                .foregroundStyle(Color.mixTextPrimary)
                            Text("We've sent a password reset link to\n\(vm.resetEmail)")
                                .font(.mixBody)
                                .foregroundStyle(Color.mixTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        Button("Done") { dismiss() }
                            .font(.mixButton)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.mixPrimary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 24)

                    } else {
                        VStack(spacing: 12) {
                            Text("Reset Password")
                                .font(.mixTitle)
                                .foregroundStyle(Color.mixTextPrimary)
                            Text("Enter your email and we'll send you a reset link.")
                                .font(.mixBody)
                                .foregroundStyle(Color.mixTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        MixtapeTextField(
                            label: "Email",
                            placeholder: "you@example.com",
                            text: $vm.resetEmail,
                            icon: "envelope",
                            isEmail: true
                        )
                        .padding(.horizontal, 24)

                        Button {
                            Task { await vm.sendPasswordReset() }
                        } label: {
                            Group {
                                if vm.isResettingPassword {
                                    ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 24)
                                } else {
                                    Text("Send Reset Link").font(.mixButton).frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.vertical, 16)
                            .background(vm.resetEmail.contains("@") ? Color.mixPrimary : Color.mixPrimary.opacity(0.4))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(!vm.resetEmail.contains("@") || vm.isResettingPassword)
                        .padding(.horizontal, 24)
                    }

                    Spacer()
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel") {
                        vm.resetEmailSent = false
                        dismiss()
                    }
                    .foregroundStyle(Color.mixTextSecondary)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SignInView(authService: AppDependencies().authService)
}
