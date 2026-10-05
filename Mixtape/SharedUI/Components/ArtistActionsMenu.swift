// Artist context menu. Takes a name and reads songs off `deps`, like
// `AlbumActionsMenu`. No Add to Library (artists aren't stored) and no Get Info.

import SwiftUI

struct ArtistActionsMenu: View {

    let name: String
    /// Overrides the share card cover (Home's remote image for artists with no row).
    var artwork: ShareItem.Artwork? = nil
    /// Off in a page's "...", which sits beside that page's own Share button.
    var showsShare = true

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    var body: some View {
        // Songs are resolved in the closures, never in the body, to keep grids smooth.
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
            // Reversed so the songs keep their order.
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

        AddToCrateMenu(item: .artist(name))

        Divider()

        BulkDownloadMenuItems(tracks: tracks(), downloads: deps.downloadManager)

        Divider()

        Button("Go to Artist", systemImage: "music.mic") {
            #if os(macOS)
            appState.openDiscoverArtist(named: name)
            #else
            iosAppState.openOnlineArtist(name: name)
            #endif
        }
        if showsShare { ShareMenuItems(shareItem) }
    }

    // MARK: - Songs

    /// Nil for artists only reached through a track credit.
    private var row: Artist? { deps.libraryService.artist(named: name) }

    private func tracks() -> [Track] {
        guard let row else { return [] }
        return deps.libraryService.tracks(by: row)
    }

    /// Only songs with audio, so the queue doesn't stall.
    private func playableTracks() -> [Track] { tracks().filter(\.canResolveAudio) }

    private var shareItem: ShareItem {
        if let artwork { return .artist(name: name, artwork: artwork) }
        if let row     { return .artist(row) }
        return .artist(name: name, artwork: .none)
    }

    private func play(shuffled: Bool) {
        let list = playableTracks()
        engine.queue.setShuffle(shuffled)
        guard let first = shuffled ? list.randomElement() : list.first else { return }
        // Stored per artist so the page's shuffle button agrees.
        if shufflePrefs.shuffles(.artist(name)) != shuffled {
            shufflePrefs.toggle(.artist(name))
        }
        Task { await engine.play(track: first, in: list, source: .named(name)) }
    }
}
