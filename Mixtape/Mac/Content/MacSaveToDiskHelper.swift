// MacSaveToDiskHelper.swift
// Mixtape — Mac/Content

import SwiftUI

#if os(macOS)
@MainActor
func macSaveToDisk(track: Track, deps: AppDependencies) {
    macSaveToDisk(tracks: [track], deps: deps)
}

/// Exports a whole selection: the folder is asked for once and the songs are
/// written one after another, so picking twenty songs doesn't mean twenty
/// panels racing each other for the same answer.
@MainActor
func macSaveToDisk(tracks: [Track], deps: AppDependencies) {
    guard !tracks.isEmpty else { return }
    Task {
        if ExportManager.shared.exportURL == nil {
            let picked: URL? = await withCheckedContinuation { cont in
                FolderPickerHelper.show { url in cont.resume(returning: url) }
            }
            guard let folder = picked else { return }   // user cancelled
            do { try ExportManager.shared.setExportURL(folder) }
            catch { deps.showToast(error.localizedDescription); return }
        }

        var saved = 0
        for track in tracks {
            do {
                // Finding the audio — cached, downloaded, imported, on Supabase,
                // or only resolvable from the internet — is the download
                // manager's job, and it is the same job here.
                if !deps.downloadManager.status(for: track).isAvailableOffline {
                    deps.showToast("Fetching \"\(track.title)\"…")
                }
                try await deps.downloadManager.saveFileCopy(of: track)
                saved += 1
            } catch {
                deps.showToast(error.localizedDescription)
            }
        }

        if saved == 1, let only = tracks.first {
            deps.showToast("Saved \"\(only.title)\"")
        } else if saved > 1 {
            deps.showToast("Saved \(saved) songs")
        }
    }
}
#endif
