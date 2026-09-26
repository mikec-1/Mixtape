// ArtistActionsMenu.swift
// Mixtape — SharedUI/Components
//
// Everything an artist can do, in one list, wherever you right-click one.
//
// Artists were the last container still stuck at two items: the Mac's artist
// grid offered "Play Artist" and "Add to Queue", Home's shelf offered "Open
// Artist" and "Play", the search results offered nothing at all, and the artist
// page — alone among the detail pages — had no overflow menu, so there was no
// way to queue an artist or download everything by one.
//
// Modelled on `AlbumActionsMenu`, and self-contained for the same reason: it
// takes a name and reads the songs off `deps`, so a row shows the same menu as
// the page without the page's loaded state.
//
// No "Add to Library": an artist isn't a thing the library holds — it's the
// songs that are saved, and the row only exists because some of them are. No
// "Get Info" either; `GetInfoSheet` answers questions about a file, and the
// artist page already is this artist's information.

import SwiftUI

struct ArtistActionsMenu: View {

    let name: String
    /// Overrides the cover on the share card. Home's shelf holds a remote image
    /// for artists with no library row of their own, which is the only artwork
    /// those have.
    var artwork: ShareItem.Artwork? = nil
    /// Off in a page's "…", which sits beside that page's own Share button.
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
        // Songs are resolved inside the closures, never in the body: this menu
        // is rebuilt with the row it hangs off, and walking the library for the
        // artist's tracks there is the cost that made these grids stutter.
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
            // Reversed, so each insert lands after the one before it and the
            // songs keep their order in the queue.
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

    /// The library row behind this name, when there is one. An artist reached
    /// only through a track credit has none.
    private var row: Artist? { deps.libraryService.artist(named: name) }

    private func tracks() -> [Track] {
        guard let row else { return [] }
        return deps.libraryService.tracks(by: row)
    }

    /// Songs with audio behind them. A queue that stops dead partway through
    /// reads as a broken player rather than as a missing song.
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
        // Remembered per artist, so the page's own shuffle button agrees with
        // what the menu just did.
        if shufflePrefs.shuffles(.artist(name)) != shuffled {
            shufflePrefs.toggle(.artist(name))
        }
        Task { await engine.play(track: first, in: list, source: .named(name)) }
    }
}
