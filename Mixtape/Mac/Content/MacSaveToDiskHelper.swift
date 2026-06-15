// MacSaveToDiskHelper.swift
// Mixtape — Mac/Content

import SwiftUI

#if os(macOS)
@MainActor
func macSaveToDisk(track: Track, deps: AppDependencies) {
    Task {
        do {
            if ExportManager.shared.exportURL == nil {
                let picked: URL? = await withCheckedContinuation { cont in
                    FolderPickerHelper.show { url in cont.resume(returning: url) }
                }
                guard let folder = picked else { return }   // user cancelled
                try ExportManager.shared.setExportURL(folder)
            }

            let data: Data
            let src: URL
            var tempURL: URL? = nil

            if let cached = deps.fileStorage.localURL(for: track) {
                src = cached
            } else {
                deps.showToast("Fetching track data...")
                data = try await deps.fileStorage.downloadRawData(track: track, accessToken: "")
                let ext = URL(fileURLWithPath: track.file.remoteKey ?? "").pathExtension
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try data.write(to: tmp, options: .atomic)
                tempURL = tmp
                src     = tmp
            }

            try ExportManager.shared.export(track: track, from: src)
            if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }
            deps.showToast("Saved \"\(track.title)\"")
        } catch {
            deps.showToast(error.localizedDescription)
        }
    }
}
#endif
