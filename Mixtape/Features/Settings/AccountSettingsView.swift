// AccountSettingsView.swift
// Mixtape — Features/Settings
//
// Self-contained account management content: change username, email, password.
// Presented by SettingsView inside a sheet (NavigationStack + Done button),
// so this view does NOT create its own NavigationStack.

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#elseif os(macOS)
import AppKit
#endif

public struct AccountSettingsView: View {

    @EnvironmentObject private var deps: AppDependencies

    // MARK: Profile Picture
    @State private var avatarBusy: Bool = false
    @State private var avatarResult: ActionResult?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

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
            avatarSection
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

    private var avatarSection: some View {
        Section {
            HStack(spacing: 16) {
                AvatarView(
                    url: deps.authService.currentUser?.avatarURL,
                    fallbackText: currentUsername,
                    size: 72
                )

                VStack(alignment: .leading, spacing: 8) {
                    #if os(iOS)
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        Text(avatarBusy ? "Uploading…" : "Change Photo")
                            .font(.mixButton)
                            .foregroundStyle(avatarBusy ? Color.mixTextTertiary : Color.mixPrimary)
                    }
                    .disabled(avatarBusy)
                    #else
                    Button {
                        pickAvatarMac()
                    } label: {
                        Text(avatarBusy ? "Uploading…" : "Change Photo")
                            .font(.mixButton)
                            .foregroundStyle(avatarBusy ? Color.mixTextTertiary : Color.mixPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(avatarBusy)
                    #endif

                    if deps.authService.currentUser?.avatarURL != nil {
                        Button(role: .destructive) {
                            removeAvatar()
                        } label: {
                            Text("Remove")
                                .font(.mixCaptionBold)
                                .foregroundStyle(Color.mixDestructive)
                        }
                        .buttonStyle(.plain)
                        .disabled(avatarBusy)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            resultText(avatarResult)
        } header: {
            sectionHeader("Profile Picture")
        }
        .listRowBackground(Color.mixSurface)
        #if os(iOS)
        .onChange(of: photoItem) { _, newItem in
            handlePickedPhoto(newItem)
        }
        #endif
    }

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

    // MARK: Avatar Actions

    #if os(iOS)
    private func handlePickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        avatarResult = nil
        avatarBusy = true
        Task {
            defer { avatarBusy = false; photoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    avatarResult = .failure("Couldn't read that image.")
                    return
                }
                try await uploadAndSetAvatar(data)
            } catch {
                avatarResult = .failure(error.localizedDescription)
            }
        }
    }
    #else
    private func pickAvatarMac() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        avatarResult = nil
        avatarBusy = true
        Task {
            defer { avatarBusy = false }
            do {
                let data = try Data(contentsOf: url)
                try await uploadAndSetAvatar(data)
            } catch {
                avatarResult = .failure(error.localizedDescription)
            }
        }
    }
    #endif

    /// Downsamples the picked image, uploads it, and persists the URL on the profile.
    private func uploadAndSetAvatar(_ data: Data) async throws {
        guard let jpeg = ImageDownsampler.downsampledJPEG(from: data) else {
            avatarResult = .failure("That image couldn't be processed.")
            return
        }
        let url = try await deps.authService.uploadAvatar(jpeg, fileExtension: "jpg")
        try await deps.authService.updateAvatarURL(url)
        avatarResult = .success("Profile picture updated.")
    }

    private func removeAvatar() {
        avatarResult = nil
        avatarBusy = true
        Task {
            defer { avatarBusy = false }
            do {
                try await deps.authService.updateAvatarURL(nil)
                avatarResult = .success("Profile picture removed.")
            } catch {
                avatarResult = .failure(error.localizedDescription)
            }
        }
    }

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
