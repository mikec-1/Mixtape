// WelcomeDownloadPrompt.swift
// Mixtape — App
//
// Shown on first launch after sign-in when no export location has been chosen.
// Presents the default folder and lets the user proceed — or, on macOS, pick a
// different one or skip.
//
// This used to be a 420×560 onboarding screen: a 56pt glyph, a display-sized
// welcome, and three centred paragraphs stacked between Spacers, with the two
// buttons floating at the bottom of the column. It's one decision — where do
// files go — so it's one sentence, one card, and a button bar.

import SwiftUI

struct WelcomeDownloadPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var exportManager: ExportManager

    @State private var errorMessage: String? = nil

    /// A human-readable version of the folder we're proposing.
    private var suggestedDisplayPath: String {
        #if os(macOS)
        let url = exportManager.suggestedURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        #else
        return "On My iPhone / Mixtape"
        #endif
    }

    private var blurb: String {
        if exportManager.hasGlobalExportPath {
            let whose = exportManager.globalExportPathOwner.map { "for \($0)" } ?? "on this Mac"
            return "Keep using the folder you already chose \(whose)? Songs go in a subfolder named after the account, so they stay separate."
        }
        #if os(macOS)
        return "Songs you export are saved to a folder on this Mac, so you can play them anywhere — even without Mixtape."
        #else
        return "Songs you export are saved to the Files app under On My iPhone, so you can play them anywhere — even without Mixtape."
        #endif
    }

    var body: some View {
        MixSheet(title: "Welcome to Mixtape",
                 subtitle: blurb,
                 size: .compact) {
            location
        } footer: {
            actions
        }
    }

    // MARK: - Location

    private var location: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Mixtape")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(suggestedDisplayPath)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                #if os(macOS)
                // Only on the Mac, where the user has a file system to point at.
                Button("Change\u{2026}") {
                    FolderPickerHelper.show { url in handlePicked(url) }
                }
                .buttonStyle(.plain).mixHandCursor()
                .font(.mixLabel)
                .foregroundStyle(Color.mixPrimary)
                .mixHoverCursor { _ in }
                #endif
            }
            .padding(14)
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let errorMessage {
                MixSheetStatus(kind: .failure,
                               title: "Couldn't use that folder",
                               detail: errorMessage)
            }
        }
    }

    // MARK: - Actions

    /// Skipping isn't cancelling — it records a choice — so it doesn't ride on
    /// the chrome's dismiss button.
    private var actions: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("Skip for now") {
                exportManager.setDidSkip(true)
                dismiss()
            }
            .buttonStyle(.plain).mixHandCursor()
            .foregroundStyle(Color.mixTextSecondary)
            .keyboardShortcut(.cancelAction)

            MixSheetPrimaryButton(
                action: MixSheetAction("Use This Location", action: useDefaultLocation),
                fullWidth: false
            )
            .keyboardShortcut(.defaultAction)
        }
        #else
        MixSheetPrimaryButton(
            action: MixSheetAction("Continue", action: useDefaultLocation),
            fullWidth: true
        )
        #endif
    }

    private func useDefaultLocation() {
        do {
            try exportManager.setDefaultMixtapeFolder()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func handlePicked(_ url: URL?) {
        guard let url else { return }
        do {
            try exportManager.setExportURL(url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif
}
