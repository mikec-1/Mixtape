// MacHomeSurface.swift
// Mixtape — Mac/Content
//
// The Home sections plus the wiring that makes their callbacks mean something
// on macOS.
//
// This used to be written inline in MacContentRouter's `.home` case. Home is
// the opening stretch of the merged Discover landing now — not a tab, and not a
// page of its own — so this renders `HomeSections`: content with no scroll view
// and no margins, which the landing supplies.
//
// `showsRecommendations` is off because the landing's own "Made for you" is
// directly below these sections and is the better version of the same idea:
// same listening history, whole catalogue behind it instead of just the library.

#if os(macOS)
import SwiftUI

struct MacHomeSurface: View {

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState

    /// Which stretch of Home this instance draws. The landing renders the
    /// greeting and shelf above "Made for you" and the library rows below it,
    /// so the wiring below is written once and used twice.
    var bands: HomeBands = .all

    var body: some View {
        HomeSections(
            onQuickLink: { link in
                switch link {
                case .songs:     appState.selection = .songs
                case .albums:    appState.selection = .albums
                case .artists:   appState.selection = .artists
                case .playlists: appState.selection = .playlists
                }
            },
            onPlay: { track, context, origin in
                // Route online (Discover) tracks through the coordinator;
                // local tracks play on the offline engine.
                Task {
                    if deps.onlineCoordinator.isStandaloneOnline(track) {
                        await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
                    } else {
                        await engine.play(track: track, in: context, source: .named(origin))
                    }
                }
            },
            // Discover, whether or not the library holds a row for the name —
            // the same answer the player bar, the queue and every song menu
            // give. Preferring the local artist made Home's shelf lead to two
            // different kinds of page depending on what was saved.
            onArtist: { appState.openDiscoverArtist(named: $0) },
            onPlaylist: { playlist in
                appState.selectedPlaylist = playlist
                appState.selectedAlbum    = nil
                appState.selection        = nil
            },
            onSmartPlaylist: { appState.showSmartPlaylist($0) },
            showsRecommendations: false,
            bands: bands
        )
    }
}

#endif
