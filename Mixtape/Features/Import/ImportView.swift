// Import sheet from the library toolbar, using the system file picker.

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
    // Used to queue enrichment candidates for review after import.
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    /// Passed explicitly into the nested link sheet.
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

    /// The open link sheet, if any. See `LinkImportView.Service`.
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
                #if os(iOS)
                .environmentObject(iosAppState)
                #endif
        }
        .sheet(isPresented: $showSpotifyImport) {
            SpotifyImportView(spotifyClient: spotifyClient,
                              importService: spotifyImportService,
                              auth: spotifyAuth,
                              followService: deps.spotifyFollowService,
                              ledger: deps.spotifyImportLedger)
        }
        #if os(iOS)
        // A sheet can't open over this one from the tab view, so the review shows here while it's up.
        .onAppear { iosAppState.importSheetOpen = true }
        .onDisappear { iosAppState.importSheetOpen = false }
        .sheet(item: Binding(
            get: { linkService == nil && !showSpotifyImport ? iosAppState.pendingReview : nil },
            set: { _ in iosAppState.dequeueReview() }
        )) { item in
            IOSMetadataReviewSheet(item: item)
                .environmentObject(deps)
                .environmentObject(iosAppState)
        }
        #endif
    }

    // MARK: - Sub-Views

    /// The import routes, as option rows.
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

                // One row per service so YouTube support is visible.
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

                // Below the single-playlist row since it's the bigger commitment. Opens Settings,
                // where the Spotify connection lives.
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
            return  // T user cancelled
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
                        _ = review  // T unused on macOS (MacImportButton does the import)
                    case .duplicate: duplicateCount += 1
                    case .failed:    failedCount    += 1
                    }
                }

                isImporting = false
                buildResultMessage()

                withMixAnimation(.mixSnappy) {
                    showResultBanner = true
                }

                // Auto-dismiss the banner after 3 seconds, then close sheet if all succeeded
                try? await Task.sleep(for: .seconds(3))
                withMixAnimation { showResultBanner = false }
                #if os(iOS)
                // Stay up while the review is showing over it.
                if failedCount == 0 && iosAppState.pendingReview == nil { dismiss() }
                #else
                if failedCount == 0 { dismiss() }
                #endif
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
