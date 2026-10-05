// Home sections wired up for macOS, rendered as the top of the merged Discover landing.
// `showsRecommendations` is off because the landing's own "Made for you" follows directly.

#if os(macOS)
import SwiftUI

struct MacHomeSurface: View {

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState

    /// Which part of Home to draw: greeting and shelf above "Made for you", library rows below.
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
                // Online tracks go through the coordinator; local ones play on the offline engine.
                Task {
                    if deps.onlineCoordinator.isStandaloneOnline(track) {
                        await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
                    } else {
                        await engine.play(track: track, in: context, source: .named(origin))
                    }
                }
            },
            // Always Discover, like every other artist link.
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
