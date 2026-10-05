// Add-to-library and download controls for local and Discover album pages.

import SwiftUI

struct AlbumSaveButton: View {
    let title: String
    let artistName: String
    /// Discover imports its songs here.
    var onSave: (() -> Void)? = nil

    @ObservedObject private var saved = SavedAlbumsService.shared

    private var isSaved: Bool { saved.isSaved(title: title, artistName: artistName) }

    var body: some View {
        Button {
            let now = !isSaved
            saved.setSaved(now, title: title, artistName: artistName)
            if now { onSave?() }
        } label: {
            HeroCircleLabel(systemImage: isSaved ? "checkmark" : "plus",
                            foreground: isSaved ? .mixOnAccent : .mixTextSecondary,
                            fill: isSaved ? .mixPrimary : .mixSurface)
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .accessibilityLabel(isSaved ? "Remove from Library" : "Add to Library")
    }
}

struct AlbumDownloadButton: View {
    /// The album's songs as library ids.
    let ids: [UUID]
    @ObservedObject var downloads: DownloadManager
    let library: LibraryService
    /// Discover saves the album first so there are rows to download.
    var prepare: (() async -> Void)? = nil

    @State private var confirmRemove = false

    var body: some View {
        let fraction = downloads.downloadFraction(ids)
        let done = downloads.isFullyDownloaded(ids)
        Button {
            if fraction != nil {
                downloads.stopDownloads(for: ids)
            } else if done {
                confirmRemove = true
            } else {
                Task {
                    await prepare?()
                    for id in ids { if let t = library.track(id: id) { downloads.download(t) } }
                }
            }
        } label: {
            HeroCircleLabel(systemImage: fraction != nil ? "stop.fill" : done ? "arrow.down.circle.fill" : "arrow.down",
                            foreground: fraction != nil || done ? .green : .mixTextSecondary,
                            progress: fraction, progressTint: .green)
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .accessibilityLabel(fraction != nil ? "Stop download" : done ? "Remove download" : "Download")
        .mixConfirmationDialog("Remove these downloads?", isPresented: $confirmRemove) {
            Button("Remove Downloads", role: .destructive) { ids.forEach(downloads.removeDownload(for:)) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
