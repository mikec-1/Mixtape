// UsernamePromptView.swift
// Mixtape
//
// One-time nudge after first social sign-in to replace the auto-generated
// `user_xxxxxxxx` handle. Skippable — Skip keeps the auto name.

import SwiftUI

struct UsernamePromptView: View {

    @ObservedObject var authService: SupabaseAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isSaving  = false
    @State private var errorText: String?
    @State private var revealPassword = false

    private var validationError: String? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < 3 { return "At least 3 characters required." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Letters, numbers, and underscores only."
        }
        return nil
    }

    /// Password is optional, but if the user typed one it must be ≥ 8 chars.
    private var passwordError: String? {
        guard !password.isEmpty else { return nil }
        return password.count >= 8 ? nil : "At least 8 characters required."
    }

    private var isValid: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 && validationError == nil && passwordError == nil
    }

    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                ZStack {
                    Circle()
                        .fill(Color.mixPrimary.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "at")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.mixPrimary)
                }

                VStack(spacing: 8) {
                    Text("Finish setting up")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("Pick a username so other listeners can find you. You can also set a password to sign in with your email next time.")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "at")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.mixTextTertiary)
                            .frame(width: 18)
                        TextField("username", text: $username)
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextPrimary)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    .padding(14)
                    .background(Color.mixSurface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                (validationError ?? errorText) != nil
                                    ? Color.mixDestructive.opacity(0.6)
                                    : Color.mixSeparator,
                                lineWidth: 1
                            )
                    )

                    if let err = validationError ?? errorText {
                        Text(err)
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixDestructive)
                    }
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.mixTextTertiary)
                            .frame(width: 18)
                        Group {
                            if revealPassword {
                                TextField("Password (optional)", text: $password)
                            } else {
                                SecureField("Password (optional)", text: $password)
                            }
                        }
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.mixTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(Color.mixSurface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                passwordError != nil
                                    ? Color.mixDestructive.opacity(0.6)
                                    : Color.mixSeparator,
                                lineWidth: 1
                            )
                    )

                    Text(passwordError ?? "Optional — leave blank to keep signing in with Google.")
                        .font(.mixCaption)
                        .foregroundStyle(passwordError != nil ? Color.mixDestructive : Color.mixTextTertiary)
                }
                .padding(.horizontal, 24)

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(.white).frame(height: 24).frame(maxWidth: .infinity)
                        } else {
                            Text("Save").font(.mixButton).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 16)
                    .background(isValid ? Color.mixPrimary : Color.mixPrimary.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!isValid || isSaving)
                .padding(.horizontal, 24)

                Button("Skip for now") {
                    authService.dismissUsernamePrompt()
                    dismiss()
                }
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextTertiary)
                .buttonStyle(.plain)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 360)
        }
        .onAppear {
            if username.isEmpty, let suggested = authService.suggestedUsername {
                username = suggested
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func save() async {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            try await authService.chooseUsername(trimmed, password: password.isEmpty ? nil : password)
            dismiss()
        } catch let error as AuthError {
            errorText = error.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}
