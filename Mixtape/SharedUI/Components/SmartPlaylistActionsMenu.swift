// SmartPlaylistActionsMenu.swift
// Mixtape — SharedUI/Components
//
// What you can do to a smart playlist from its row, in one place.
//
// Not `PlaylistActionsMenu`: that one reads the playlist back out of the
// library for nearly every item — pin, duplicate, publish, Spotify link — and a
// smart playlist's id belongs to a rule, not to a library row, so all of those
// lookups would miss. A rule also has no contents to reorder and no remote to
// sync with. This is the short list that is actually true of one.
//
// It replaces two rows that had drifted: the Mac library's Smart section
// offered Delete and nothing else, and the Playlists tab's smart rows offered
// no menu at all.

import SwiftUI

struct SmartPlaylistActionsMenu: View {

    let playlist: SmartPlaylist
    @ObservedObject var service: SmartPlaylistService

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        // Every item resolves the rule inside its closure, never in the body:
        // a rule is matched against the whole library, and a context menu is
        // rebuilt with the row it hangs off.
        Button {
            play(shuffled: false)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            play(shuffled: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Divider()

        Button {
            deps.onlineCoordinator.addToQueue(localTracks: tracks())
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        Button(role: .destructive) {
            service.delete(id: playlist.id)
        } label: {
            Label("Delete Smart Playlist", systemImage: "trash")
        }
    }

    /// The songs the rule resolves to right now, minus the ones with no audio
    /// behind them — a queue that stops dead partway through reads as a broken
    /// player.
    private func tracks() -> [Track] {
        deps.smartTrackIDs(playlist)
            .compactMap { deps.libraryService.track(id: $0) }
            .filter(\.canResolveAudio)
    }

    private func play(shuffled: Bool) {
        let list = tracks()
        deps.playbackEngine.queue.setShuffle(shuffled)
        guard let first = shuffled ? list.randomElement() : list.first else { return }
        Task {
            await deps.playbackEngine.play(
                track: first, in: list,
                source: .playlist(id: playlist.id, name: playlist.name)
            )
        }
    }
}
