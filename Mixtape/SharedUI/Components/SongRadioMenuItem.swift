// "Go to Song Radio" for every track menu. Sets a pending request on app state;
// the Discover tab builds and pushes it, like "Go to Artist".

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

    /// Printed title, without the feature credit.
    init(track: Track) {
        self.title = track.displayTitle
        self.artistName = track.displayArtistName
    }

    init(song: OnlineTrack) {
        self.title = song.title
        self.artistName = song.displayArtistName
    }

    var body: some View {
        // Built from the catalogue, so hidden when offline.
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
