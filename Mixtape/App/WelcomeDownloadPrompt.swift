// WelcomeDownloadPrompt.swift
// Mixtape — App
//
// Shown on first launch after sign-in when no export location has been chosen.
// Presents the default folder (Documents/Mixtape) and lets the user proceed.
// On macOS: provides a "Change Location" option.
// On iOS: simplified layout to just show "On My iPhone / Mixtape" with a single "Continue" button.

import SwiftUI

struct WelcomeDownloadPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var exportManager: ExportManager
    
    #if os(macOS)
    @State private var showPicker = false
    #endif
    @State private var errorMessage: String? = nil

    // Derive a human-readable default path to display (~/Documents/Mixtape on macOS)
    // Derive a human-readable suggested path to display
    private var suggestedDisplayPath: String {
        #if os(macOS)
        let url = exportManager.suggestedURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        #else
        return "On My iPhone / Mixtape"
        #endif
    }

    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──────────────────────────────────────────────────
                VStack(spacing: 16) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.mixPrimary)
                        .padding(.top, 40)

                    Text("Welcome to Mixtape")
                        .font(.mixDisplay)
                        .foregroundStyle(Color.mixTextPrimary)
                        .multilineTextAlignment(.center)

                    let username = exportManager.currentUsername ?? "your account"
                    if exportManager.hasGlobalExportPath {
                        (Text("Would you like to keep using your previously chosen folder for ") +
                         Text(username).bold() +
                         Text("? Your files will be saved in a subfolder named after your username to keep them isolated."))
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    } else {
                        #if os(macOS)
                        Text("When you export songs from your library, they'll be saved to a folder on your device so you can access them anytime — even without the app.")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        #else
                        Text("When you export songs from your library, they'll be saved directly to the Files app under On My iPhone so you can access them anytime — even without the app.")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        #endif
                    }
                }

                Spacer(minLength: 24)

                // ── Default Location Card ────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default Location")
                        .font(.mixCaptionBold)
                        .foregroundStyle(Color.mixTextTertiary)
                        .textCase(.uppercase)

                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.mixPrimary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mixtape")
                                .font(.mixBodyBold)
                                .foregroundStyle(Color.mixTextPrimary)
                            Text(suggestedDisplayPath)
                                .font(.mixCaption)
                                .foregroundStyle(Color.mixTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()
                    }
                    .padding(16)
                    .background(Color.mixSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.mixPrimary.opacity(0.3), lineWidth: 1)
                    )

                    #if os(macOS)
                    // Change link (macOS only)
                    Button {
                        FolderPickerHelper.show { url in
                            handlePicked(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                               .font(.system(size: 12))
                            Text("Change Location")
                                .font(.mixCaption)
                        }
                        .foregroundStyle(Color.mixPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    #endif
                }
                #if os(macOS)
                .padding(.horizontal, 28)
                #else
                .padding(.horizontal, 24)
                #endif

                if let err = errorMessage {
                    Text(err)
                        .font(.mixCaption)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 24)

                // ── Primary Action ────────────────────────────────────────────
                Button {
                    useDefaultLocation()
                } label: {
                    #if os(macOS)
                    Text("Use This Location")
                        .font(.mixButtonSmall)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.mixPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    #else
                    Text("Continue")
                        .font(.mixButtonSmall)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.mixPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    #endif
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                #else
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                #endif

                #if os(macOS)
                Button("Skip for now") {
                    exportManager.setDidSkip(true)
                    dismiss()
                }
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.bottom, 32)
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 520, idealHeight: 560)
        #endif
    }

    // MARK: - Actions

    private func useDefaultLocation() {
        do {
            try exportManager.setDefaultMixtapeFolder()
            dismiss()
        } catch {
            errorMessage = "Couldn't create folder: \(error.localizedDescription)"
        }
    }

    #if os(macOS)
    private func handlePicked(_ url: URL?) {
        guard let url else { return }
        do {
            try exportManager.setExportURL(url)
            dismiss()
        } catch {
            errorMessage = "Couldn't save location: \(error.localizedDescription)"
        }
    }
    #endif
}
