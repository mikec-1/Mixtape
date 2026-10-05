// Download section of a track's context menu, shared by every surface.

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DownloadMenuItems: View {

    let track: Track
    @ObservedObject var downloads: DownloadManager

    @ViewBuilder
    var body: some View {
        statusItems
        #if os(macOS)
        // Any local file counts (import, download, cache). `fileOnDisk` stats the
        // disk, so it's asked once when the menu opens.
        if let url = track.fileOnDisk {
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusItems: some View {
        switch downloads.status(for: track.id) {

        case .streamOnly:
            // No row when there's nothing to fetch from.
            if downloads.downloadUnavailableReason(for: track) == nil {
                Button("Download", systemImage: "arrow.down.circle") {
                    downloads.download(track)
                }
            }

        case .downloading(let progress):
            Button(progress > 0 ? "Downloading \(Int(progress * 100))%" : "Downloading\u{2026}",
                   systemImage: "arrow.down.circle") {}
                .disabled(true)

        case .offline:
            Button("Remove Download", systemImage: "xmark.circle") {
                downloads.removeDownload(for: track.id)
            }

        case .failed:
            Button("Retry Download", systemImage: "arrow.clockwise.circle") {
                downloads.download(track)
            }
            if let reason = downloads.failureReason(for: track.id) {
                Text(reason)
            }

        case .local:
            // Imported from disk: already offline, nothing to offer.
            EmptyView()
        }
    }
}

// MARK: - A selection of songs

/// Same section for a selection: counts of what can still be downloaded or
/// removed. Items with nothing to act on are hidden.
struct BulkDownloadMenuItems: View {

    let tracks: [Track]
    @ObservedObject var downloads: DownloadManager

    /// Songs with nothing on disk and somewhere to fetch from.
    private var downloadable: [Track] {
        tracks.filter {
            let status = downloads.status(for: $0.id)
            guard !status.isAvailableOffline, !status.isDownloading else { return false }
            return downloads.downloadUnavailableReason(for: $0) == nil
        }
    }

    /// Only app downloads; imported files are the user's.
    private var removable: [Track] {
        tracks.filter { downloads.status(for: $0.id).isRemovableDownload }
    }

    var body: some View {
        if !downloadable.isEmpty {
            Button("Download \(downloadable.count) Songs", systemImage: "arrow.down.circle") {
                for track in downloadable { downloads.download(track) }
            }
        }
        if !removable.isEmpty {
            Button("Remove \(removable.count) Downloads", systemImage: "xmark.circle") {
                for track in removable { downloads.removeDownload(for: track.id) }
            }
        }
    }
}

#if os(macOS)
extension Track {
    /// Downloads live in the offline store with an empty `localPath`, so check both.
    var fileOnDisk: URL? {
        AudioPaths.resolve(localPath: file.localPath) ?? OfflineStore.shared.url(for: id)
    }
}
#endif
