// Album context menu. Takes an `Album` and reads songs off `deps`, so rows
// and the page share it (like `PlaylistActionsMenu`).

import SwiftUI

struct AlbumActionsMenu: View {

    let album: Album
    /// Off in a page's "...", which sits beside that page's own Share button.
    var showsShare = true

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    #if os(macOS)
    @Environment(MacAppState.self) private var appState
    #else
    @Environment(IOSAppState.self) private var iosAppState
    #endif
    private var saved: SavedAlbumsService { .shared }
    private var shufflePrefs: ShufflePreferences { .shared }

    var body: some View {
        // Songs are resolved in the closures, never in the body, to keep lists smooth.
        Button {
            play(shuffled: false)
        } label: {
            Label("Play", systemImage: MixtapeIcons.play)
        }

        Button {
            play(shuffled: true)
        } label: {
            Label("Shuffle", systemImage: MixtapeIcons.shuffle)
        }

        Divider()

        Button {
            // Reversed so the album keeps its order.
            for song in playableTracks().reversed() { engine.queue.insertNext(song) }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            deps.onlineCoordinator.addToQueue(localTracks: playableTracks())
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        Button {
            saved.setSaved(!isSaved, title: album.title, artistName: album.artistName)
        } label: {
            Label(isSaved ? "Remove from Library" : "Add to Library",
                  systemImage: isSaved ? "checkmark.circle.fill" : "plus.circle")
        }
        AddToCrateMenu(item: .album(title: album.title, artist: album.artistName))

        Divider()

        BulkDownloadMenuItems(tracks: tracks(), downloads: deps.downloadManager)

        Divider()

        goToArtist
        if showsShare { ShareMenuItems(.album(album)) }
    }

    // MARK: - Artist

    /// Split like track rows, so "A & B" offers both.
    @ViewBuilder
    private var goToArtist: some View {
        let credits = ImportService.creditedArtists(from: album.artistName)
        if credits.count > 1 {
            Menu("Go to Artist") {
                ForEach(credits, id: \.self) { name in
                    Button(name) { openArtist(named: name) }
                }
            }
        } else if let name = credits.first, !name.isEmpty {
            Button("Go to Artist", systemImage: "music.mic") { openArtist(named: name) }
        }
    }

    private func openArtist(named name: String) {
        #if os(macOS)
        appState.openDiscoverArtist(named: name)
        #else
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    // MARK: - Songs

    private var isSaved: Bool { saved.isSaved(album) }

    private func tracks() -> [Track] { deps.libraryService.tracks(in: album) }

    /// Only songs with audio, so the queue doesn't stall.
    private func playableTracks() -> [Track] { tracks().filter(\.canResolveAudio) }

    private func play(shuffled: Bool) {
        let list = playableTracks()
        engine.queue.setShuffle(shuffled)
        guard let first = shuffled ? list.randomElement() : list.first else { return }
        // Stored per album so the page's shuffle button agrees.
        if shufflePrefs.shuffles(.album(album.id)) != shuffled {
            shufflePrefs.toggle(.album(album.id))
        }
        Task { await engine.play(track: first, in: list, source: .named(album.title)) }
    }
}
