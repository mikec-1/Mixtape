// ImportView.swift
// Mixtape — Features/Import
//
// Sheet presented when the user taps the import button in the library toolbar.
// Uses SwiftUI's .fileImporter() to open the system file picker for audio files.

import SwiftUI
import UniformTypeIdentifiers

public struct ImportView: View {

    // MARK: - Dependencies

    let importService: ImportService
    let spotifyClient: SpotifyClient
    let spotifyImportService: SpotifyImportService
    let spotifyAuth: SpotifyAuth

    public init(
        importService: ImportService,
        spotifyClient: SpotifyClient,
        spotifyImportService: SpotifyImportService,
        spotifyAuth: SpotifyAuth
    ) {
        self.importService = importService
        self.spotifyClient = spotifyClient
        self.spotifyImportService = spotifyImportService
        self.spotifyAuth = spotifyAuth
    }

    #if os(iOS)
    // Receives the IOSAppState injected by MainTabView; used to enqueue
    // enrichment candidates for review after import completes.
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    /// Only so the link sheet can be handed it explicitly. This view takes its
    /// own services by hand, but a nested sheet is a new presentation and it's
    /// cheaper to pass the container than to reason about what it inherits.
    @EnvironmentObject private var deps: AppDependencies

    // MARK: - State

    @State private var showFilePicker    = false
    @State private var isImporting       = false
    @State private var importedCount     = 0
    @State private var duplicateCount    = 0
    @State private var failedCount       = 0
    @State private var showResultBanner  = false
    @State private var resultMessage     = ""
    @State private var showSpotifyImport = false

    /// Which link sheet is up, if any — see `LinkImportView.Service`.
    @State private var linkService: LinkImportView.Service?

    @Environment(\.dismiss) private var dismiss

    // MARK: - Supported Audio Types

    private let audioTypes: [UTType] = [
        .mp3, .mpeg4Audio, .aiff, .wav,
        UTType("public.flac") ?? .audio,
        UTType("public.ogg-audio") ?? .audio,
        UTType("com.apple.coreaudio-format") ?? .audio,
    ].uniqued()

    // MARK: - Body

    public var body: some View {
        MixSheet(title: "Add Music",
                 subtitle: "Import audio files from this device, or paste a link to a song.",
                 size: .medium) {
            routes
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: true
        ) { result in
            handlePickerResult(result)
        }
        .sheet(item: $linkService) { service in
            LinkImportView(service: service)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showSpotifyImport) {
            SpotifyImportView(spotifyClient: spotifyClient,
                              importService: spotifyImportService,
                              auth: spotifyAuth,
                              followService: deps.spotifyFollowService,
                              ledger: deps.spotifyImportLedger)
        }
    }

    // MARK: - Sub-Views

    /// Four ways in, as rows.
    ///
    /// This was a 120pt circle over a centred heading over four stacked pill
    /// buttons, each capped at 240pt and floating in the middle of the sheet.
    /// Four equally-sized pills give no sense of which one you want and leave
    /// no room to say what any of them do; rows do both, and they don't need
    /// the sheet to be mostly empty in order to look composed.
    private var routes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isImporting {
                MixSheetStatus(kind: .busy, title: "Importing\u{2026}")
            } else {
                MixSheetOptionRow(icon: MixtapeIcons.importFile,
                                  title: "Choose Files",
                                  detail: "MP3, AAC, FLAC, AIFF and WAV.",
                                  isPreferred: true) {
                    showFilePicker = true
                }

                // Each service is named, rather than one "Add from a Link":
                // the combined entry gave no sign YouTube was supported, and
                // this screen is where anyone would look.
                MixSheetOptionRow(icon: "link",
                                  title: "Import Spotify Link",
                                  detail: "One song, from a track link.") {
                    linkService = .spotify
                }

                MixSheetOptionRow(icon: "link",
                                  title: "Import YouTube Link",
                                  detail: "One song, from a video address.") {
                    linkService = .youTube
                }

                MixSheetOptionRow(icon: "music.note.list",
                                  title: "Import Spotify Playlist",
                                  detail: "Recreates it with the same cover and songs.") {
                    showSpotifyImport = true
                }

                // Below the single-playlist row on purpose: this is the bigger
                // commitment, and someone who came here for one playlist
                // shouldn't have to step over a whole-library migration to
                // reach it.
                // Opens Settings rather than stacking another sheet on this
                // one: Spotify is a connection now, and the picker lives with
                // the account it reads from.
                MixSheetOptionRow(icon: "square.stack.3d.down.right",
                                  title: "Import Spotify Library",
                                  detail: "Pick from your playlists, Liked Songs and saved albums.") {
                    dismiss()
                    SettingsRoute.shared.openSpotifyLibrary()
                }
            }

            if showResultBanner {
                resultBanner
                    .transition(.opacity)
            }
        }
    }

    private var resultBanner: some View {
        MixSheetStatus(kind: failedCount > 0 ? .failure : .success,
                       title: resultMessage)
    }

    // MARK: - Import Logic

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            return   // user cancelled — no-op
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task {
                isImporting = true
                showResultBanner = false
                importedCount = 0
                duplicateCount = 0
                failedCount = 0

                let results = await importService.importTracks(from: urls)

                for r in results {
                    switch r {
                    case .imported(_, let review):
                        importedCount += 1
                        #if os(iOS)
                        iosAppState.enqueueReview(review)
                        #endif
                        _ = review // unused on macOS (primary import is via MacImportButton)
                    case .duplicate: duplicateCount += 1
                    case .failed:    failedCount    += 1
                    }
                }

                isImporting = false
                buildResultMessage()

                withMixAnimation(.spring(duration: 0.3)) {
                    showResultBanner = true
                }

                // Auto-dismiss the banner after 3 seconds, then close sheet if all succeeded
                try? await Task.sleep(for: .seconds(3))
                withMixAnimation { showResultBanner = false }
                if failedCount == 0 { dismiss() }
            }
        }
    }

    private func buildResultMessage() {
        var parts: [String] = []
        if importedCount  > 0 { parts.append("\(importedCount) added")    }
        if duplicateCount > 0 { parts.append("\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s")") }
        if failedCount    > 0 { parts.append("\(failedCount) failed")      }
        resultMessage = parts.isEmpty ? "Nothing to import" : parts.joined(separator: " · ")
    }
}

// MARK: - UTType Helpers

private extension Array where Element == UTType {
    /// Remove duplicates while preserving order.
    func uniqued() -> [UTType] {
        var seen = Set<String>()
        return filter { seen.insert($0.identifier).inserted }
    }
}
