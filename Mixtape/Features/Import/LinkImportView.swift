// Paste a Spotify or YouTube link, get the song. `MusicLink` detects the
// service, so either sheet accepts either link; there's one per service only so
// the menu names both. Used by the macOS "+" menu and iOS Add Music.

import SwiftUI

public struct LinkImportView: View {

    /// The service the sheet was opened for. Wording only. `Identifiable` for `.sheet(item:)`.
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
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var appState: IOSAppState
    #endif
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
    /// New songs from this sheet, reviewed once it closes.
    @State private var imported: [Track] = []
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
            primary: primaryAction,
            secondary: secondaryAction
        ) {
            content
        }
        .onAppear { fieldFocused = true }
        // Two sheets can't be up at once, so the review waits for this one to go.
        .onDisappear {
            for track in imported { appState.enqueueReview(MetadataReviewItem(imported: track)) }
        }
    }

    // MARK: - Sub-views

    /// The field, with the last attempt's result underneath and progress in the footer button.
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

                // Explicit paste so iOS doesn't show a clipboard banner unprompted.
                Button("Paste") {
                    if let clipboard = Self.clipboardString() { link = clipboard }
                }
                .buttonStyle(.plain).mixHandCursor()
                .font(.system(size: MixFontScale.size(13), weight: .medium))
                .foregroundStyle(Color.mixPrimary)
            }

            statusLine
        }
    }

    /// The last attempt's result, if any.
    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .input:
            EmptyView()

        case .working:
            // One song of unknown length, so no progress fraction.
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

    /// Driven by the phase. After success it becomes Done.
    private var primaryAction: MixSheetAction {
        if case .finished = phase {
            return MixSheetAction("Done") { dismiss() }
        }
        return MixSheetAction("Add Song", isEnabled: canImport, isBusy: phase == .working, action: start)
    }

    /// Replaces Cancel after success.
    private var secondaryAction: MixSheetAction? {
        guard case .finished = phase else { return nil }
        return MixSheetAction("Import Another") {
            link = ""
            phase = .input
            fieldFocused = true
        }
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
                if !outcome.alreadySaved { imported.append(outcome.track) }
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
