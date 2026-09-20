// UsernamePromptView.swift
// Mixtape
//
// One-time nudge after first social sign-in to replace the auto-generated
// `user_xxxxxxxx` handle. Skippable — Skip keeps the auto name.

import SwiftUI

struct UsernamePromptView: View {

    @ObservedObject var authService: SupabaseAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
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
        if authService.promptNameOnly {
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 && validationError == nil && passwordError == nil
    }

    var body: some View {
        // This was an 80pt circled glyph over a centred paragraph over two
        // full-width pills, in a 420×460 window — a phone's welcome screen with
        // a Mac frame around it. It asks for one name and one optional
        // password, so it looks like what it is: a short form.
        MixSheet(title: authService.promptNameOnly ? "Add a Display Name" : "Finish Setting Up",
                 subtitle: authService.promptNameOnly
                    ? "Your display name can be anything. Your username stays how people find you."
                    : "Choose your name and a username other listeners can find you by.",
                 size: .medium) {
            fields
        } footer: {
            actions
        }
        .onAppear {
            if username.isEmpty, let suggested = authService.suggestedUsername {
                username = suggested
            }
            if displayName.isEmpty, let suggested = authService.suggestedDisplayName {
                displayName = suggested
            }
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Display name", text: $displayName)
                .mixSheetField()

            if authService.promptNameOnly {
                if let errorText {
                    Text(errorText)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixDestructive)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("@")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.mixTextTertiary)
                        TextField("username", text: $username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    .mixSheetField()

                    if let err = validationError ?? errorText {
                        Text(err)
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixDestructive)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Group {
                            if revealPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.mixTextTertiary)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                    .mixSheetField()

                    Text(passwordError ?? "Optional \u{2014} leave it blank to keep signing in with Google.")
                        .font(.mixCaption)
                        .foregroundStyle(passwordError != nil ? Color.mixDestructive : Color.mixTextTertiary)
                }
            }
        }
    }

    // MARK: - Actions

    /// Skip records a decision (never ask again), so it isn't the chrome's
    /// dismiss button — it's its own control that says what it does.
    private var actions: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            skipButton
                .keyboardShortcut(.cancelAction)
            MixSheetPrimaryButton(action: saveAction, fullWidth: false)
                .keyboardShortcut(.defaultAction)
        }
        #else
        VStack(spacing: 10) {
            MixSheetPrimaryButton(action: saveAction, fullWidth: true)
            skipButton
        }
        #endif
    }

    private var skipButton: some View {
        Button("Skip for now") {
            authService.dismissUsernamePrompt()
            dismiss()
        }
        .buttonStyle(.plain).mixHandCursor()
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.mixTextSecondary)
    }

    private var saveAction: MixSheetAction {
        MixSheetAction("Save", isEnabled: isValid, isBusy: isSaving) {
            Task { await save() }
        }
    }

    private func save() async {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            if authService.promptNameOnly {
                try await authService.updateDisplayName(displayName)
                authService.dismissUsernamePrompt()
                dismiss()
                return
            }
            try await authService.chooseUsername(trimmed, displayName: displayName,
                                                 password: password.isEmpty ? nil : password)
            dismiss()
        } catch let error as AuthError {
            errorText = error.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}
