// AlbumActionsMenu.swift
// Mixtape — SharedUI/Components
//
// Everything an album can do, in one list, wherever you right-click one.
//
// Albums had almost nothing. The album page's hero offered Play, Shuffle, Save
// and Download and no overflow menu at all, so there was no way to queue an
// album or reach its artist from it; the Mac's album rows offered a single
// "Remove from Library"; and on iPhone the only gesture an album row had was a
// destructive swipe.
//
// Modelled on `PlaylistActionsMenu`, and deliberately self-contained for the
// same reason: it takes an `Album` and reads its songs off `deps`, so a row can
// show the same menu as the page without the page's loaded state.

import SwiftUI

struct AlbumActionsMenu: View {

    let album: Album
    /// Off in a page's "…", which sits beside that page's own Share button.
    var showsShare = true

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @ObservedObject private var saved       = SavedAlbumsService.shared
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    var body: some View {
        // Songs are resolved inside the closures, never in the body: this menu
        // is rebuilt with the row it hangs off, and walking the library for the
        // album's tracks there is the cost that made these lists stutter before.
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
            // album keeps its running order in the queue.
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

    /// The credited artists, split the way a track row splits them: a
    /// compilation credited to "A & B" offers both rather than searching for
    /// the whole string and finding nobody.
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

    /// Songs with audio behind them. A queue that stops dead partway through
    /// reads as a broken player rather than as a missing song.
    private func playableTracks() -> [Track] { tracks().filter(\.canResolveAudio) }

    private func play(shuffled: Bool) {
        let list = playableTracks()
        engine.queue.setShuffle(shuffled)
        guard let first = shuffled ? list.randomElement() : list.first else { return }
        // Remembered per album, so the page's own shuffle button agrees with
        // what the menu just did.
        if shufflePrefs.shuffles(.album(album.id)) != shuffled {
            shufflePrefs.toggle(.album(album.id))
        }
        Task { await engine.play(track: first, in: list, source: .named(album.title)) }
    }
}
