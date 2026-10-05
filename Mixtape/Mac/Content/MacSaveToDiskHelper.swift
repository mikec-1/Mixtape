import SwiftUI

#if os(macOS)
@MainActor
func macSaveToDisk(track: Track, deps: AppDependencies) {
    macSaveToDisk(tracks: [track], deps: deps)
}

/// Export a selection with one folder prompt, writing the songs in turn.
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
            catch { deps.showToast(.failed(error.localizedDescription)); return }
        }

        var saved = 0
        for track in tracks {
            do {
                // Finding the audio is the download manager's job.
                if !deps.downloadManager.status(for: track).isAvailableOffline {
                    deps.showToast("Fetching \"\(track.title)\"…")
                }
                try await deps.downloadManager.saveFileCopy(of: track)
                saved += 1
            } catch {
                deps.showToast(.failed(error.localizedDescription))
            }
        }

        if saved == 1, let only = tracks.first {
            deps.showToast(.done("Saved \"\(only.title)\""))
        } else if saved > 1 {
            deps.showToast(.done("Saved \(saved) songs"))
        }
    }
}
#endif
