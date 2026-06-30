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

    // MARK: - State

    @State private var showFilePicker    = false
    @State private var isImporting       = false
    @State private var importedCount     = 0
    @State private var duplicateCount    = 0
    @State private var failedCount       = 0
    @State private var showResultBanner  = false
    @State private var resultMessage     = ""
    @State private var showSpotifyImport = false

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
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    importIllustration

                    VStack(spacing: 12) {
                        Text("Add Music")
                            .font(.mixTitle)
                            .foregroundStyle(Color.mixTextPrimary)

                        Text("Import audio files from your device.\nMP3, AAC, FLAC, AIFF and WAV are supported.")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if isImporting {
                        ProgressView("Importing…")
                            .tint(Color.mixPrimary)
                            .foregroundStyle(Color.mixTextSecondary)
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Choose Files", systemImage: MixtapeIcons.importFile)
                                .font(.mixButton)
                                .frame(maxWidth: 240)
                                .padding(.vertical, 14)
                                .background(Color.mixPrimary)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showSpotifyImport = true
                        } label: {
                            Label("Import from Spotify", systemImage: "music.note.list")
                                .font(.mixButton)
                                .frame(maxWidth: 240)
                                .padding(.vertical, 14)
                                .background(Color.mixSurface)
                                .foregroundStyle(Color.mixTextPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    if showResultBanner {
                        resultBanner
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Spacer()
                }
            }
            .navigationTitle("Import Music")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.mixPrimary)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: audioTypes,
                allowsMultipleSelection: true
            ) { result in
                handlePickerResult(result)
            }
            .sheet(isPresented: $showSpotifyImport) {
                SpotifyImportView(spotifyClient: spotifyClient,
                                  importService: spotifyImportService,
                                  auth: spotifyAuth)
            }
        }
    }

    // MARK: - Sub-Views

    private var importIllustration: some View {
        ZStack {
            Circle()
                .fill(Color.mixSurface)
                .frame(width: 120, height: 120)
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(Color.mixPrimary)
        }
    }

    private var resultBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failedCount > 0 ? Color.mixAccent : Color.mixSuccess)
            Text(resultMessage)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
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
                    case .imported(let track, let candidate):
                        importedCount += 1
                        #if os(iOS)
                        iosAppState.enqueueReview(MetadataReviewItem(track: track, candidate: candidate))
                        #endif
                        _ = (track, candidate) // suppress unused warning on macOS (primary import is via MacImportButton)
                    case .duplicate: duplicateCount += 1
                    case .failed:    failedCount    += 1
                    }
                }

                isImporting = false
                buildResultMessage()

                withAnimation(.spring(duration: 0.3)) {
                    showResultBanner = true
                }

                // Auto-dismiss the banner after 3 seconds, then close sheet if all succeeded
                try? await Task.sleep(for: .seconds(3))
                withAnimation { showResultBanner = false }
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
