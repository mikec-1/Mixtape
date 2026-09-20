// SongRadioMenuItem.swift
// Mixtape — SharedUI/Components
//
// "Go to Song Radio" — one item, every track menu.
//
// StationBuilder has built radios since the Discover shelf existed, but the
// only way to reach one was to be handed it: a card on Home, or an artist
// page. A song you were already listening to couldn't start one. This is that
// entry point, and it is the same shape on both platforms — set a pending
// request on the app state, let the Discover tab resolve it and push the page,
// exactly as "Go to Artist" does.

import SwiftUI

struct SongRadioMenuItem: View {

    let title: String
    let artistName: String

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    /// The printed song, not the stored one: a radio titled with the feature
    /// credit still attached reads as a mistake.
    init(track: Track) {
        self.title = track.displayTitle
        self.artistName = track.displayArtistName
    }

    init(song: OnlineTrack) {
        self.title = song.title
        self.artistName = song.displayArtistName
    }

    var body: some View {
        // The station is built from the catalogue, so with no network there is
        // no radio to go to — and a row that explains why it can't work is
        // worse than no row.
        if deps.downloadManager.isConnected, !title.isEmpty, !artistName.isEmpty {
            Button("Go to Song Radio", systemImage: "dot.radiowaves.left.and.right") {
                #if os(macOS)
                appState.showSongRadio(title: title, artistName: artistName)
                #else
                iosAppState.openSongRadio(title: title, artistName: artistName)
                #endif
            }
        }
    }
}
