// LinkImportView.swift
// Mixtape — Features/Import
//
// Paste a Spotify or YouTube link, get the song.
//
// One field handles both — `MusicLink` works out which service it is, and a
// link pasted into the "wrong" one still imports. The sheet is still opened
// *per service* because a single "Add from a Link" entry left no sign that
// YouTube was supported at all; naming both in the menu is the only place the
// user looks. Everything below the title is the same code either way.
//
// Shown from the macOS "+" menu and the iOS Add Music sheet. The only
// platform-specific parts are the keyboard hints and the sheet frame.

import SwiftUI

public struct LinkImportView: View {

    /// Which service the sheet was opened for. Affects wording only.
    ///
    /// `Identifiable` so callers can drive the sheet with `.sheet(item:)` — two
    /// menu entries opening one sheet is a choice of *which*, not two
    /// independent booleans that could both be true.
    public enum Service: Identifiable {
        case spotify
        case youTube

        public var id: String { title }

        var title: String {
            switch self {
            case .spotify: return "Import from Spotify"
            case .youTube: return "Import from YouTube"
            }
        }

        var blurb: String {
            switch self {
            case .spotify:
                return "Share \u{2192} Copy Song Link in Spotify, then paste it here."
            case .youTube:
                return "Copy the address of a YouTube video, then paste it here."
            }
        }

        var placeholder: String {
            switch self {
            case .spotify: return "https://open.spotify.com/track/\u{2026}"
            case .youTube: return "https://youtube.com/watch?v=\u{2026}"
            }
        }
    }

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case input
        case working
        case finished(title: String, artist: String, alreadySaved: Bool)
        case failed(String)
    }

    private let service: Service

    @State private var link = ""
    @State private var phase: Phase = .input
    @FocusState private var fieldFocused: Bool

    public init(service: Service) {
        self.service = service
    }

    // MARK: - Body

    public var body: some View {
        MixSheet(
            title: service.title,
            subtitle: service.blurb,
            size: .compact,
            primary: primaryAction
        ) {
            content
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Sub-views

    /// One field and whatever the last attempt has to say about itself.
    ///
    /// This used to be three full-page states behind a `switch` — a 120pt
    /// circle over a centred heading, then a page that was nothing but a
    /// spinner, then a page that was nothing but a checkmark. Each one threw
    /// away the field and replaced the sheet wholesale, which is a lot of
    /// motion for "we are looking it up". The field stays put now and the
    /// outcome arrives underneath it; the wait shows up in the footer button,
    /// where the thing you pressed is.
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField(service.placeholder, text: $link)
                    .focused($fieldFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(start)
                    .mixSheetField()

                // Explicit rather than reading the clipboard on appear: iOS
                // shows the user a "pasted from" banner either way, and a
                // banner they didn't ask for reads as the app snooping.
                Button("Paste") {
                    if let clipboard = Self.clipboardString() { link = clipboard }
                }
                .buttonStyle(.plain).mixHandCursor()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixPrimary)
            }

            statusLine
        }
    }

    /// The result of the last attempt, inline. Nothing here is load-bearing —
    /// when there's nothing to say, there's nothing drawn, and the sheet is
    /// just a field.
    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .input:
            EmptyView()

        case .working:
            // No progress fraction: this is one song, and the resolve is of
            // unknown length.
            MixSheetStatus(kind: .busy,
                           title: "Finding the song\u{2026}",
                           detail: "The audio is downloaded, not linked, so give it a few seconds.")

        case .failed(let message):
            MixSheetStatus(kind: .failure,
                           title: "Couldn't import that link",
                           detail: message)

        case .finished(let title, let artist, let alreadySaved):
            MixSheetStatus(kind: alreadySaved ? .noop : .success,
                           title: alreadySaved ? "Already in your library" : "Added to your library",
                           detail: "\(title) \u{2014} \(artist)")
        }
    }

    /// One button that reads the phase, rather than a different button per page.
    /// After a successful import it becomes "Add Another", so the sheet stays
    /// open for the second link — which is how anyone actually uses this.
    private var primaryAction: MixSheetAction {
        if case .finished = phase {
            return MixSheetAction("Add Another") {
                link = ""
                phase = .input
                fieldFocused = true
            }
        }
        return MixSheetAction("Add Song", isEnabled: canImport, isBusy: phase == .working, action: start)
    }

    // MARK: - Actions

    private var canImport: Bool {
        !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .working
    }

    private func start() {
        guard canImport else { return }
        phase = .working
        Task {
            do {
                let outcome = try await deps.linkImport.importTrack(from: link)
                phase = .finished(title: outcome.track.title,
                                  artist: outcome.track.artistName,
                                  alreadySaved: outcome.alreadySaved)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private static func clipboardString() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
