// SpotifyLikesPushRow.swift
// Mixtape — Features/Settings
//
// The way in to the favourites-push page.
//
// This row used to do the whole job itself: a confirmation dialog, then a
// silent run that liked every confident match. It was wrong in a way that only
// showed up on the second run — with one favourite already saved on Spotify, it
// still offered to "like 1 song", and liking it changed nothing. The work of
// deciding what's actually missing belongs on a page that can show its working,
// so this is now a door, and the page behind it does the checking.
//
// It stays additive, which is the promise worth keeping: unhearting something
// here is not a request to unlike it on Spotify. The two lists have separate
// histories and no shared record of who removed what.

import SwiftUI

struct SpotifyLikesPushRow: View {

    @EnvironmentObject private var deps: AppDependencies
    /// Observed for the connection itself. Note the favourite count below is
    /// read through `deps`, which is a nested ObservableObject and does not
    /// republish: a favourite added while this pane is open won't flip the row
    /// until something else redraws it.
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
