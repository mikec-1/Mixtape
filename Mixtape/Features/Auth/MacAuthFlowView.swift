// MacAuthFlowView.swift
// Mixtape — Features/Auth
//
// Four-screen macOS onboarding.
//
// Flow:
//   MacAuthLandingView      — logo + wordmark + "Sign In" / "Create Account"
//       ↓ Sign In           → MacSignInView   (passkey-first, email fallback)
//       ↓ Create Account    → MacCreateAccountView → MacCheckEmailView (if confirmation needed)
//
// Navigation is a simple enum + spring animation — no NavigationStack needed.
// The AuthViewModel is unchanged; each screen sets vm.isSignUpMode before submit().

#if os(macOS)
import SwiftUI

// MARK: - Screen State

private enum MacAuthScreen: Equatable {
    case landing, signIn, createAccount, checkEmail, setNewPassword
}

// MARK: - Flow Container

struct MacAuthFlowView: View {

    @StateObject  private var vm:          AuthViewModel
    @ObservedObject private var authService: SupabaseAuthService
    @State private var screen:      MacAuthScreen = .landing
    @State private var pushForward: Bool          = true

    init(authService: SupabaseAuthService) {
        _vm          = StateObject(wrappedValue: AuthViewModel(authService: authService))
        _authService = ObservedObject(wrappedValue: authService)
    }

    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            Group {
                switch screen {
                case .landing:
                    MacAuthLandingView(
                        onSignIn:        { navigate(to: .signIn,         forward: true) },
                        onCreateAccount: { navigate(to: .createAccount,  forward: true) }
                    )
                    .transition(slide(forward: pushForward))

                case .signIn:
                    MacSignInView(vm: vm, onBack: { navigate(to: .landing, forward: false) })
                        .transition(slide(forward: pushForward))

                case .createAccount:
                    MacCreateAccountView(vm: vm, onBack: { navigate(to: .landing, forward: false) })
                        .transition(slide(forward: pushForward))

                case .checkEmail:
                    MacCheckEmailView(
                        vm:     vm,
                        onBack: { navigate(to: .createAccount, forward: false) }
                    )
                    .transition(slide(forward: pushForward))

                case .setNewPassword:
                    MacSetNewPasswordView(vm: vm)
                        .transition(slide(forward: pushForward))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: screen)
        }
        .frame(minWidth: 480, minHeight: 540)
        .alert("Error", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "Something went wrong. Please try again.")
        }
        // Navigate to checkEmail as soon as the VM signals it
        .onChange(of: vm.showCheckEmail) { _, show in
            if show { navigate(to: .checkEmail, forward: true) }
        }
        // Navigate to setNewPassword when a password-reset deep link is handled
        .onChange(of: authService.isAwaitingPasswordReset) { _, isWaiting in
            if isWaiting { navigate(to: .setNewPassword, forward: true) }
        }
    }

    private func navigate(to destination: MacAuthScreen, forward: Bool) {
        pushForward = forward
        screen = destination
    }

    private func slide(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion:  .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal:    .move(edge: forward ? .leading  : .trailing).combined(with: .opacity)
        )
    }
}

// MARK: - Landing

private struct MacAuthLandingView: View {

    let onSignIn:        () -> Void
    let onCreateAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Wordmark
            VStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.mixPrimary)

                VStack(spacing: 5) {
                    Text("Mixtape")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.mixTextPrimary)
                        .tracking(-0.5)

                    Text("Your music, everywhere.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer().frame(height: 56)

            VStack(spacing: 11) {
                MixAuthPrimaryButton("Sign In", action: onSignIn)
                MixAuthSecondaryButton("Create Account", action: onCreateAccount)
            }
            .frame(maxWidth: 300)

            Spacer()

            Text("Your files. Your library. No algorithms.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary.opacity(0.45))
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sign In

private struct MacSignInView: View {

    @ObservedObject var vm: AuthViewModel
    let onBack: () -> Void

    @State private var showPasskeyAlert   = false
    @State private var showForgotPassword = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            MixAuthBackButton(action: onBack)
                .padding(.horizontal, 40)
                .padding(.top, 32)

            VStack(spacing: 30) {
                authHeading(
                    title:    "Welcome back",
                    subtitle: "Sign in to your Mixtape account"
                )

                Button {
                    showPasskeyAlert = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 13))
                        Text("Sign in with Passkey")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundStyle(Color.mixTextPrimary)
                    .background(Color.mixSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.mixSeparator, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .alert("Passkeys Coming Soon", isPresented: $showPasskeyAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Passkey sign-in will be available in a future update. Please use email and password for now.")
                }

                MixAuthDivider(label: "or continue with email")

                VStack(spacing: 12) {
                    MixAuthField(
                        label:        "Email",
                        placeholder:  "you@example.com",
                        text:         $vm.email,
                        errorMessage: vm.emailError
                    )
                    MixAuthField(
                        label:        "Password",
                        placeholder:  "Password",
                        text:         $vm.password,
                        isSecure:     true,
                        errorMessage: vm.passwordError
                    )

                    HStack {
                        Spacer()
                        Button("Forgot password?") {
                            vm.resetEmail = vm.email
                            showForgotPassword = true
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextTertiary)
                        .buttonStyle(.plain)
                    }
                    .padding(.top, -4)
                }

                MixAuthPrimaryButton(
                    vm.isLoading ? "" : "Sign In",
                    isLoading: vm.isLoading,
                    isEnabled: vm.isFormValid && !vm.isLoading
                ) {
                    Task { await vm.submit() }
                }
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { vm.isSignUpMode = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showForgotPassword) {
            MacForgotPasswordSheet(vm: vm)
        }
    }
}

// MARK: - Create Account

private struct MacCreateAccountView: View {

    @ObservedObject var vm: AuthViewModel
    let onBack: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            MixAuthBackButton(action: onBack)
                .padding(.horizontal, 40)
                .padding(.top, 32)

            VStack(spacing: 30) {
                authHeading(
                    title:    "Create account",
                    subtitle: "Your library lives in the cloud."
                )

                VStack(spacing: 12) {
                    MixAuthField(
                        label:        "Username",
                        placeholder:  "Choose a username",
                        text:         $vm.username,
                        errorMessage: vm.usernameError
                    )
                    MixAuthField(
                        label:        "Email",
                        placeholder:  "you@example.com",
                        text:         $vm.email,
                        errorMessage: vm.emailError
                    )
                    MixAuthField(
                        label:        "Password",
                        placeholder:  "Min. 8 characters",
                        text:         $vm.password,
                        isSecure:     true,
                        errorMessage: vm.passwordError
                    )
                }

                MixAuthPrimaryButton(
                    vm.isLoading ? "" : "Create Account",
                    isLoading: vm.isLoading,
                    isEnabled: vm.isFormValid && !vm.isLoading
                ) {
                    Task { await vm.submit() }
                }
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { vm.isSignUpMode = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Check Email (shown after signup when confirmation is required)

private struct MacCheckEmailView: View {

    @ObservedObject var vm: AuthViewModel
    let onBack: () -> Void

    @State private var didResend = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            MixAuthBackButton(action: onBack)
                .padding(.horizontal, 40)
                .padding(.top, 32)

            VStack(spacing: 32) {

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.mixPrimary.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.mixPrimary)
                }

                VStack(spacing: 10) {
                    Text("Check your inbox")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)

                    VStack(spacing: 4) {
                        Text("We sent a verification link to")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mixTextTertiary)
                        Text(vm.email)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                    }

                    Text("Click the link in the email to activate your account.\nThen return here — the app will sign you in automatically.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                        .padding(.top, 4)
                }

                // Resend button
                if didResend {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.mixPrimary)
                            .font(.system(size: 13))
                        Text("Email resent")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                    .transition(.opacity)
                } else {
                    Button {
                        Task {
                            await vm.resendConfirmationEmail()
                            withAnimation { didResend = true }
                            // Reset after 8 s so they can resend again if needed
                            Task {
                                try? await Task.sleep(for: .seconds(8))
                                withAnimation { didResend = false }
                            }
                        }
                    } label: {
                        Text(vm.isLoading ? "" : "Resend email")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isLoading)
                    .overlay {
                        if vm.isLoading { ProgressView().scaleEffect(0.6) }
                    }
                }

                Text("Check your spam folder if you don't see it within a minute.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextTertiary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: didResend)
    }
}

// MARK: - Set New Password (shown after a password-reset deep link is opened)

private struct MacSetNewPasswordView: View {

    @ObservedObject var vm: AuthViewModel

    var body: some View {
        VStack(spacing: 30) {

            // Icon
            ZStack {
                Circle()
                    .fill(Color.mixPrimary.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "lock.rotation")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.mixPrimary)
            }

            authHeading(
                title:    "Set new password",
                subtitle: "Your identity has been verified.\nCreate a new password to continue."
            )

            VStack(spacing: 12) {
                MixAuthField(
                    label:        "New password",
                    placeholder:  "Min. 8 characters",
                    text:         $vm.newPassword,
                    isSecure:     true,
                    errorMessage: vm.newPasswordError
                )
                MixAuthField(
                    label:        "Confirm password",
                    placeholder:  "Repeat new password",
                    text:         $vm.confirmNewPassword,
                    isSecure:     true,
                    errorMessage: vm.confirmPasswordError
                )
            }

            MixAuthPrimaryButton(
                vm.isUpdatingPassword ? "" : "Set Password",
                isLoading: vm.isUpdatingPassword,
                isEnabled: vm.isNewPasswordValid && !vm.isUpdatingPassword
            ) {
                Task { await vm.updatePassword() }
            }

            // Escape hatch — destroys the recovery session so no one is locked on this screen
            Button {
                Task { await vm.signOut() }
            } label: {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Forgot Password Sheet

private struct MacForgotPasswordSheet: View {

    @ObservedObject var vm: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {

            HStack(alignment: .firstTextBaseline) {
                Text(vm.resetEmailSent ? "Check your inbox" : "Reset password")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                Button("Close") {
                    vm.resetEmailSent = false
                    dismiss()
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)
                .buttonStyle(.plain)
            }

            if vm.resetEmailSent {
                HStack(spacing: 14) {
                    Image(systemName: "envelope.badge.checkmark.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.mixPrimary)
                    Text("A reset link was sent to **\(vm.resetEmail)**")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

                Button("Done") {
                    vm.resetEmailSent = false
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color.mixPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)

            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Email address")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mixTextTertiary)
                    TextField("you@example.com", text: $vm.resetEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .autocorrectionDisabled()
                }

                Button {
                    Task { await vm.sendPasswordReset() }
                } label: {
                    Group {
                        if vm.isResettingPassword {
                            ProgressView().scaleEffect(0.7).tint(.white)
                        } else {
                            Text("Send Reset Link")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(vm.resetEmail.contains("@")
                                ? Color.mixPrimary
                                : Color.mixPrimary.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!vm.resetEmail.contains("@") || vm.isResettingPassword)
            }
        }
        .padding(28)
        .frame(width: 340)
        .background(Color.mixBackground)
    }
}

// MARK: - Shared Components

private struct MixAuthBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.mixTextTertiary)
        }
        .buttonStyle(.plain)
    }
}

private struct MixAuthPrimaryButton: View {

    let label:     String
    var isLoading: Bool    = false
    var isEnabled: Bool    = true
    var action:    (() -> Void)? = nil

    init(_ label: String, isLoading: Bool = false, isEnabled: Bool = true, action: (() -> Void)? = nil) {
        self.label     = label
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.action    = action
    }

    var body: some View {
        Button { action?() } label: {
            Group {
                if isLoading {
                    ProgressView().scaleEffect(0.75).tint(.white)
                } else {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(isEnabled && !isLoading
                        ? Color.mixPrimary
                        : Color.mixPrimary.opacity(0.35))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .animation(.easeInOut(duration: 0.14), value: isEnabled)
    }
}

private struct MixAuthSecondaryButton: View {

    let label:  String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label  = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.mixSeparator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MixAuthDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.mixSeparator).frame(height: 1)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
                .fixedSize()
            Rectangle().fill(Color.mixSeparator).frame(height: 1)
        }
    }
}

private struct MixAuthField: View {

    let label:        String
    let placeholder:  String
    @Binding var text: String
    var isSecure:     Bool    = false
    var errorMessage: String? = nil

    @State  private var isRevealed = false
    @FocusState private var hasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mixTextTertiary)

            HStack(spacing: 8) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextPrimary)
                .focused($hasFocus)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)

                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.mixSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.12), value: hasFocus)

            if let err = errorMessage, !text.isEmpty {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mixDestructive)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: errorMessage != nil && !text.isEmpty)
    }

    private var borderColor: Color {
        if let errorMessage, !errorMessage.isEmpty, !text.isEmpty {
            return Color.mixDestructive.opacity(0.65)
        }
        return hasFocus ? Color.mixPrimary.opacity(0.5) : Color.mixSeparator
    }
}

private func authHeading(title: String, subtitle: String) -> some View {
    VStack(spacing: 7) {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.mixTextPrimary)
        Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(Color.mixTextTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .center)
}

#endif
