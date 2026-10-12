// Debug builds only. Launching with `-ScreenshotSetup YES` sizes the window for the website shots
// and opens a "Screenshots" playlist, made the first time from songs with covers, studio edits first.

#if DEBUG && os(macOS)
import AppKit

@MainActor
enum ScreenshotSetup {
    static let playlistName = "Screenshots"

    static func run(_ deps: AppDependencies) async {
        guard UserDefaults.standard.bool(forKey: "ScreenshotSetup") else { return }
        let library = deps.libraryService
        // The library finishes loading a moment after sign-in.
        for _ in 0..<60 where library.tracks.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !library.tracks.isEmpty else { return }

        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
            window.center()
        }
        let id = library.playlists.first { $0.name == playlistName }?.id ?? make(deps)
        Toast.openPlaylist(id)
    }

    /// 20 songs from different albums, so the cover and the list both look full.
    private static func make(_ deps: AppDependencies) -> UUID {
        var albums = Set<String>()
        let picks = deps.libraryService.tracks
            .filter { $0.artworkData != nil || $0.artworkKey != nil }
            .sorted { ($0.edit == nil ? 1 : 0, $1.dateImported) < ($1.edit == nil ? 1 : 0, $0.dateImported) }
            .filter { albums.insert("\($0.albumTitle)|\($0.artistName)".lowercased()).inserted }
            .prefix(20)
        let playlist = deps.libraryService.createPlaylist(name: playlistName,
                                                          description: "Test playlist for screenshots.")
        deps.addTracks(ids: picks.map(\.id), toPlaylist: playlist.id)
        return playlist.id
    }
}
#endif
