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
        .mixAnimation(.spring(response: 0.36, dampingFraction: 0.86), value: authService.isAwaitingPasswordReset)
        .mixAnimation(.spring(response: 0.36, dampingFraction: 0.86), value: vm.showCheckEmail)
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
            AuthCard(vm: vm)
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 40)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

// MARK: - Auth Card (iOS and MacAuthFlowView)

/// Glass card from the web /login and /signup pages, with the listener row under it.
/// isSignUpMode picks the fields. Forgot password opens vm.showForgotPassword.
struct AuthCard: View {

    @ObservedObject var vm: AuthViewModel

    // Same Unsplash photos as the web AuthCard.
    /// Seeds that land on four different blobs.
    private static let faces = ["rico", "sam", "jo", "zed"]

    var body: some View {
        VStack(spacing: 48) {
            card
            proof
        }
        .frame(maxWidth: 384)
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            Image(systemName: MixtapeMark.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: 48, height: 48)
                .background(Color.mixTextPrimary.opacity(0.2), in: Circle())
                .padding(.bottom, 24)

            Text("Mixtape")
                .font(.mixTitle)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.bottom, 24)

            VStack(spacing: 12) {
                if vm.isSignUpMode {
                    AuthInput(placeholder: "Display name", text: $vm.displayName)
                    AuthInput(placeholder: "Username (letters, numbers, _)", text: $vm.username,
                              error: vm.usernameError)
                }
                AuthInput(placeholder: "Email", text: $vm.email, isEmail: true, error: vm.emailError)
                AuthInput(placeholder: vm.isSignUpMode ? "Password (8+ characters)" : "Password",
                          text: $vm.password, isSecure: true, error: vm.passwordError)

                if !vm.isSignUpMode {
                    Button("Forgot your password?") {
                        vm.resetEmail = vm.email
                        vm.showForgotPassword = true
                    }
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextTertiary)
                    .buttonStyle(.plain).mixHandCursor()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Rectangle()
                .fill(Color.mixTextPrimary.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 16)

            VStack(spacing: 12) {
                Button {
                    Task { await vm.submit() }
                } label: {
                    if vm.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(vm.isSignUpMode ? "Create account" : "Sign in")
                    }
                }
                .buttonStyle(AuthPillStyle())
                .disabled(!vm.isFormValid || vm.isLoading)
                .opacity(vm.isFormValid ? 1 : 0.5)
                .mixAnimation(.easeInOut(duration: 0.15), value: vm.isFormValid)

                GoogleSignInButton { Task { await vm.signInWithGoogle() } }
                    .disabled(vm.isSocialLoading)
                    .opacity(vm.isSocialLoading ? 0.6 : 1)

                Button(action: vm.toggleMode) {
                    HStack(spacing: 4) {
                        Text(vm.isSignUpMode ? "Already have an account?" : "Don't have an account?")
                            .foregroundStyle(Color.mixTextTertiary)
                        Text(vm.isSignUpMode ? "Sign in" : "Sign up, it's free!")
                            .foregroundStyle(Color.mixTextPrimary.opacity(0.8))
                            .underline()
                    }
                    .font(.mixSubtext)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(32)
        .background(
            LinearGradient(colors: [Color.mixTextPrimary.opacity(0.06), Color.mixBackground],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
    }

    private var proof: some View {
        VStack(spacing: 8) {
            Text("Join **listeners** who already keep their music in Mixtape.")
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextTertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                ForEach(Self.faces, id: \.self) { seed in
                    BlobAvatar(seed: seed)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.mixSurface, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Placeholder-only field on a faint fill, like the web .auth-input.
private struct AuthInput: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var isEmail = false
    var error: String? = nil

    @State private var isRevealed = false
    @FocusState private var hasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .focused($hasFocus)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(isEmail ? .emailAddress : .default)
                .textInputAutocapitalization(.never)
                #endif

                if isSecure {
                    Button { isRevealed.toggle() } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.mixTextPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ring, lineWidth: 2)
            )

            if let error {
                Text(error)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixDestructive)
                    .transition(.opacity)
            }
        }
        .mixAnimation(.easeInOut(duration: 0.15), value: error)
        .mixAnimation(.easeInOut(duration: 0.12), value: hasFocus)
    }

    private var ring: Color {
        if error != nil { return Color.mixDestructive.opacity(0.6) }
        return hasFocus ? Color.mixTextTertiary : .clear
    }
}

/// Faint pill that deepens on press, sized to match GoogleSignInButton.
private struct AuthPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GoogleSignInButton.font)
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: GoogleSignInButton.height)
            .background(Color.mixTextPrimary.opacity(configuration.isPressed ? 0.2 : 0.1), in: Capsule())
            .contentShape(Capsule())
            .mixHandCursor()
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
                    .background(vm.isNewPasswordValid ? Color.mixAccentFill : Color.mixAccentFill.opacity(0.4))
                    .foregroundStyle(Color.mixOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!vm.isNewPasswordValid || vm.isUpdatingPassword)
                .padding(.horizontal, 24)

                // Cancel drops the recovery session.
                Button {
                    Task { await vm.signOut() }
                } label: {
                    Text("Cancel")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()

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
                            withMixAnimation { didResend = true }
                            Task {
                                try? await Task.sleep(for: .seconds(8))
                                withMixAnimation { didResend = false }
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
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.mixPrimary.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .disabled(vm.isLoading)
                    .padding(.horizontal, 24)
                }

                // Back to sign-in
                Button {
                    withMixAnimation { vm.showCheckEmail = false }
                } label: {
                    Text("← Back to sign in")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()

                Text("Check your spam folder if you don't see it within a minute.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer(minLength: 40)
            }
        }
        .mixAnimation(.easeInOut(duration: 0.2), value: didResend)
    }
}

// MARK: - Input Components

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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        .mixAnimation(.easeInOut(duration: 0.15), value: errorMessage)
    }
}

// MARK: - Preview

#Preview {
    SignInView(authService: AppDependencies().authService)
}
