// AccountSettingsView.swift
// Mixtape — Features/Settings
//
// Self-contained account management content: change username, email, password.
// Presented by SettingsView inside a sheet (NavigationStack + Done button),
// so this view does NOT create its own NavigationStack.

import SwiftUI

public struct AccountSettingsView: View {

    @EnvironmentObject private var deps: AppDependencies

    // MARK: Change Username
    @State private var usernameField: String = ""
    @State private var usernameBusy: Bool = false
    @State private var usernameResult: ActionResult?

    // MARK: Change Email
    @State private var emailField: String = ""
    @State private var emailBusy: Bool = false
    @State private var emailResult: ActionResult?

    // MARK: Change Password
    @State private var currentPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var passwordBusy: Bool = false
    @State private var passwordResult: ActionResult?

    public init() {}

    // MARK: - Derived

    private var currentEmail: String {
        deps.authService.currentUser?.email ?? "—"
    }

    private var currentUsername: String {
        deps.authService.currentUser?.displayName ?? "—"
    }

    private var trimmedUsername: String {
        usernameField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usernameValid: Bool {
        !trimmedUsername.isEmpty &&
        trimmedUsername.lowercased() != currentUsername.lowercased()
    }

    private var trimmedEmail: String {
        emailField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emailValid: Bool {
        trimmedEmail.contains("@") &&
        trimmedEmail.contains(".") &&
        trimmedEmail.lowercased() != currentEmail.lowercased()
    }

    private var passwordValid: Bool {
        !currentPassword.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }

    // MARK: - Body

    public var body: some View {
        List {
            currentInfoSection
            usernameSection
            emailSection
            passwordSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle("Account")
        .tint(.mixPrimary)
    }

    // MARK: - Sections

    private var currentInfoSection: some View {
        Section {
            infoRow(label: "Email", value: currentEmail)
            infoRow(label: "Username", value: currentUsername)
        } header: {
            sectionHeader("Current Account")
        }
        .listRowBackground(Color.mixSurface)
    }

    private var usernameSection: some View {
        Section {
            TextField("Username", text: $usernameField)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            resultText(usernameResult)

            saveButton(
                title: "Save Username",
                busy: usernameBusy,
                disabled: !usernameValid || usernameBusy
            ) {
                saveUsername()
            }
        } header: {
            sectionHeader("Change Username")
        }
        .listRowBackground(Color.mixSurface)
    }

    private var emailSection: some View {
        Section {
            TextField("New email", text: $emailField)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif

            Text("A confirmation email will be sent to the new address. The change takes effect once you confirm it.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)

            resultText(emailResult)

            saveButton(
                title: "Save Email",
                busy: emailBusy,
                disabled: !emailValid || emailBusy
            ) {
                saveEmail()
            }
        } header: {
            sectionHeader("Change Email")
        }
        .listRowBackground(Color.mixSurface)
    }

    private var passwordSection: some View {
        Section {
            SecureField("Current password", text: $currentPassword)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)

            SecureField("New password (min 8)", text: $newPassword)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)

            SecureField("Confirm new password", text: $confirmPassword)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)

            if !newPassword.isEmpty && !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("Passwords do not match.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixDestructive)
            }

            resultText(passwordResult)

            saveButton(
                title: "Change Password",
                busy: passwordBusy,
                disabled: !passwordValid || passwordBusy
            ) {
                savePassword()
            }
        } header: {
            sectionHeader("Change Password")
        }
        .listRowBackground(Color.mixSurface)
    }

    // MARK: - Reusable Row Builders

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
            Spacer()
            Text(value)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
    }

    @ViewBuilder
    private func resultText(_ result: ActionResult?) -> some View {
        if let result {
            Text(result.message)
                .font(.mixCaption)
                .foregroundStyle(result.isSuccess ? Color.mixSuccess : Color.mixDestructive)
        }
    }

    private func saveButton(
        title: String,
        busy: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.mixTextPrimary)
                }
                Text(busy ? "Saving…" : title)
                    .font(.mixButton)
                    .foregroundStyle(disabled ? Color.mixTextTertiary : Color.mixPrimary)
            }
        }
        .disabled(disabled)
    }

    // MARK: - Actions

    private func saveUsername() {
        usernameResult = nil
        usernameBusy = true
        Task {
            defer { usernameBusy = false }
            do {
                try await deps.authService.updateUsername(trimmedUsername)
                usernameResult = .success("Username updated.")
                usernameField = ""
            } catch {
                usernameResult = .failure(error.localizedDescription)
            }
        }
    }

    private func saveEmail() {
        emailResult = nil
        emailBusy = true
        Task {
            defer { emailBusy = false }
            do {
                try await deps.authService.updateEmail(trimmedEmail)
                emailResult = .success("Confirmation email sent to \(trimmedEmail).")
                emailField = ""
            } catch {
                emailResult = .failure(error.localizedDescription)
            }
        }
    }

    private func savePassword() {
        passwordResult = nil
        passwordBusy = true
        Task {
            defer { passwordBusy = false }
            do {
                try await deps.authService.changePassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
                passwordResult = .success("Password changed.")
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
            } catch {
                passwordResult = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Action Result

private enum ActionResult {
    case success(String)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let m): return m
        case .failure(let m): return m
        }
    }
}
