// The way into the likes-push page. Additive only: unliking here doesn't unlike on Spotify.

import SwiftUI

struct SpotifyLikesPushRow: View {

    @EnvironmentObject private var deps: AppDependencies
    /// Observed for the connection. The liked count below comes through `deps`, which doesn't
    /// republish, so it can lag until something else redraws.
    @ObservedObject var auth: SpotifyAuth
    let onOpen: () -> Void

    private var favouriteCount: Int {
        guard let playlist = deps.libraryService.playlist(id: Playlist.favouritesID) else { return 0 }
        let live = Set(deps.libraryService.tracks.filter { !$0.isDeleted }.map(\.id))
        return playlist.trackIDs.filter { live.contains($0) }.count
    }

    var body: some View {
        SettingsButtonRow(id: "connections.spotifyPushLikes",
                          title: "Add Your Likes to Spotify\u{2026}",
                          subtitle: subtitle,
                          icon: "heart.text.square",
                          role: .plain,
                          showsChevron: true,
                          isEnabled: favouriteCount > 0,
                          action: onOpen)
    }

    private var subtitle: String {
        guard favouriteCount > 0 else { return "Nothing is liked yet." }
        return "Choose which songs to add. It only adds, and never unlikes anything."
    }
}
