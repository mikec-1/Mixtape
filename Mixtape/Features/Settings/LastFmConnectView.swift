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
        MixSheet(title: "Last.fm",
                 subtitle: scrobbler.isConfigured
                     ? "Mixtape sends what you play to your Last.fm profile."
                     : "Create an API account at last.fm/api, then paste the two values it gives you.",
                 size: .medium,
                 primary: primaryAction) {
            VStack(alignment: .leading, spacing: 16) {
                if scrobbler.isConfigured {
                    connectedCard
                } else {
                    credentialsForm
                }
                if let errorText = errorText ?? scrobbler.lastAuthError {
                    MixSheetStatus(kind: .failure,
                                   title: "Couldn't connect",
                                   detail: errorText)
                }
            }
        }
        .tint(Color.mixPrimary)
    }

    /// Three steps, one button: connect, come back from the browser, finish.
    /// Each of those used to be its own full-width block inside the form, which
    /// left two buttons on screen at once with no sign which one was next.
    private var primaryAction: MixSheetAction {
        if scrobbler.isConfigured {
            return MixSheetAction("Done") { dismiss() }
        }
        if didOpenAuth {
            return MixSheetAction("Finish Connecting",
                                  isBusy: scrobbler.isConnecting) {
                Task { await finish() }
            }
        }
        return MixSheetAction("Connect",
                              isEnabled: canConnect,
                              isBusy: scrobbler.isConnecting) {
            Task { await connect() }
        }
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
            .buttonStyle(.plain).mixHandCursor()
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
        VStack(alignment: .leading, spacing: 14) {
            field(title: "API Key", text: $apiKey, secure: false)
            field(title: "Shared Secret", text: $apiSecret, secure: true)

            if didOpenAuth {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approve access in your browser, then choose Finish Connecting.")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)

                    // Only a way back to a page they already have open — it
                    // shouldn't compete with the step that's actually next.
                    Button("Re-open the authorize page") {
                        Task { await connect() }
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixPrimary)
                    .mixHoverCursor { _ in }
                }
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
            .mixSheetField()
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
