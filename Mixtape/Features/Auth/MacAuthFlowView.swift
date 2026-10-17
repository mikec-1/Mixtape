// macOS onboarding: the shared AuthCard (sign in or sign up via vm.isSignUpMode)
// -> Check Email (if confirmation is needed). A reset link jumps to Set New Password.

#if os(macOS)
import SwiftUI

// MARK: - Screen State

private enum MacAuthScreen: Equatable {
    case card, checkEmail, setNewPassword
}

// MARK: - Flow Container

struct MacAuthFlowView: View {

    @StateObject  private var vm:          AuthViewModel
    @ObservedObject private var authService: SupabaseAuthService
    @State private var screen:      MacAuthScreen = .card
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
                case .card:
                    ScrollView {
                        AuthCard(vm: vm)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 48)
                    }
                    .defaultScrollAnchor(.center)
                    .transition(slide(forward: pushForward))

                case .checkEmail:
                    MacCheckEmailView(
                        vm:     vm,
                        onBack: {
                            // Cleared so the next sign-up's onChange fires again.
                            vm.showCheckEmail = false
                            navigate(to: .card, forward: false)
                        }
                    )
                    .transition(slide(forward: pushForward))

                case .setNewPassword:
                    MacSetNewPasswordView(vm: vm)
                        .transition(slide(forward: pushForward))
                }
            }
            .mixAnimation(.mixSoft, value: screen)
        }
        .frame(minWidth: 480, minHeight: 540)
        .alert("Error", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "Something went wrong. Please try again.")
        }
        .sheet(isPresented: $vm.showForgotPassword) {
            ForgotPasswordSheet(vm: vm)
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
                            withMixAnimation { didResend = true }
                            // Reset after 8 s so they can resend again if needed
                            Task {
                                try? await Task.sleep(for: .seconds(8))
                                withMixAnimation { didResend = false }
                            }
                        }
                    } label: {
                        Text(vm.isLoading ? "" : "Resend email")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixPrimary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
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
        .mixAnimation(.easeInOut(duration: 0.2), value: didResend)
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

            // Drops the recovery session so nobody is stuck on this screen.
            Button {
                Task { await vm.signOut() }
            } label: {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .buttonStyle(.plain).mixHandCursor()
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .buttonStyle(.plain).mixHandCursor()
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
                        ? Color.mixAccentFill
                        : Color.mixAccentFill.opacity(0.35))
            .foregroundStyle(Color.mixOnAccent)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled || isLoading)
        .mixAnimation(.easeInOut(duration: 0.14), value: isEnabled)
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
                    .buttonStyle(.plain).mixHandCursor()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.mixSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .mixAnimation(.easeInOut(duration: 0.12), value: hasFocus)

            if let err = errorMessage, !text.isEmpty {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mixDestructive)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .mixAnimation(.easeInOut(duration: 0.15), value: errorMessage != nil && !text.isEmpty)
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
