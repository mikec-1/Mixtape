// DownloadMenuItems.swift
// Mixtape — SharedUI/Components
//
// The download section of a track's context menu, in one place.
//
// It used to be written out per screen, and each copy had drifted: the playlist
// menu offered Download, Remove Download and a disabled "already offline" line;
// the artist, search and queue menus offered *only* Remove Download, so a song
// could be downloaded from one list and not from another for no reason a user
// could see. The Mac table offered neither — the only way to download a single
// song on the Mac was to put it in a playlist and take the whole playlist
// offline.
//
// Five states, one list, everywhere.

import SwiftUI

struct DownloadMenuItems: View {

    let track: Track
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        switch downloads.status(for: track.id) {

        case .streamOnly:
            // Nowhere to fetch from means no row. It used to show the reason as
            // a disabled item, which reads as a dead end in a list of actions —
            // and the step it asks for ("add it to your library") is its own
            // item higher up the same menu.
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
            // Imported from disk: already offline, and re-fetching it would mean
            // downloading a file the user handed us in the first place. Nothing
            // to offer, so nothing is drawn.
            EmptyView()
        }
    }
}

// MARK: - A selection of songs

/// The same section for several songs at once.
///
/// Deliberately not five states again: a selection is usually a mix of them, and
/// the honest answer is how many of them can still be downloaded and how many
/// already have been. Items that would act on nothing don't appear at all.
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

    /// Songs this app downloaded, and so can take back off the disk. Imported
    /// files are not among them — that audio is the user's own.
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
