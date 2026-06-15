// LastFmConnectView.swift
// Mixtape — Features/Settings
//
// Sheet that walks the user through connecting their Last.fm account using the
// desktop web-auth flow:
//   1. Paste API key + shared secret (from last.fm/api/account/create).
//   2. "Connect" → opens the Last.fm authorize page in the browser.
//   3. After approving there, "Finish connecting" → fetches + stores the session key.
//
// When already connected it shows the username and a Disconnect / Forget option.

import SwiftUI

struct LastFmConnectView: View {

    @ObservedObject private var scrobbler = LastFmScrobbler.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var apiKey: String = ""
    @State private var apiSecret: String = ""
    @State private var didOpenAuth = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if scrobbler.isConfigured {
                            connectedCard
                        } else {
                            credentialsForm
                        }
                        if let errorText = errorText ?? scrobbler.lastAuthError {
                            Text(errorText)
                                .font(.mixCaption)
                                .foregroundStyle(Color.mixDestructive)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Last.fm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Color.mixPrimary)
    }

    // MARK: - Connected

    private var connectedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.mixSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(scrobbler.username.map { "as \($0)" } ?? "Last.fm account linked")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                }
            }

            Toggle(isOn: $scrobbler.isEnabled) {
                Text("Scrobble what I play")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
            }
            .tint(Color.mixPrimary)

            Button(role: .destructive) {
                scrobbler.disconnect()
            } label: {
                Text("Disconnect")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixDestructive)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface)
        )
    }

    // MARK: - Credentials form

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create an API account at last.fm/api, then paste your credentials below.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)

            field(title: "API Key", text: $apiKey, secure: false)
            field(title: "Shared Secret", text: $apiSecret, secure: true)

            Button {
                Task { await connect() }
            } label: {
                HStack {
                    if scrobbler.isConnecting { ProgressView().controlSize(.small) }
                    Text(didOpenAuth ? "Re-open authorize page" : "Connect")
                        .font(.mixBodyBold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(canConnect ? Color.mixPrimary : Color.mixSurface2)
                )
                .foregroundStyle(canConnect ? Color.white : Color.mixTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canConnect || scrobbler.isConnecting)

            if didOpenAuth {
                Text("Approve access in your browser, then tap below.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)

                Button {
                    Task { await finish() }
                } label: {
                    HStack {
                        if scrobbler.isConnecting { ProgressView().controlSize(.small) }
                        Text("Finish connecting")
                            .font(.mixBodyBold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.mixPrimary, lineWidth: 1.5)
                    )
                    .foregroundStyle(Color.mixPrimary)
                }
                .buttonStyle(.plain)
                .disabled(scrobbler.isConnecting)
            }
        }
    }

    private func field(title: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
            .textFieldStyle(.plain)
            .font(.mixBody)
            .foregroundStyle(Color.mixTextPrimary)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.mixSurface)
            )
        }
    }

    private var canConnect: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func connect() async {
        errorText = nil
        scrobbler.saveCredentials(apiKey: apiKey, apiSecret: apiSecret)
        do {
            let url = try await scrobbler.beginWebAuth()
            openURL(url)
            didOpenAuth = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finish() async {
        errorText = nil
        do {
            try await scrobbler.completeWebAuth()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
