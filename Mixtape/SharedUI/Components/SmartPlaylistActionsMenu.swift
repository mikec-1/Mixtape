// Menu for a smart playlist row. Not `PlaylistActionsMenu`: a smart playlist's
// id belongs to a rule, not a library row, and has nothing to reorder or sync.

import SwiftUI

struct SmartPlaylistActionsMenu: View {

    let playlist: SmartPlaylist
    @ObservedObject var service: SmartPlaylistService

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        // Songs are resolved in the closures, never in the body; the rule matches
        // against the whole library.
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
            // Reversed so the rule's order survives into the queue.
            for song in tracks().reversed() { deps.playbackEngine.queue.insertNext(song) }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            deps.onlineCoordinator.addToQueue(localTracks: tracks())
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        BulkDownloadMenuItems(tracks: tracks(), downloads: deps.downloadManager)

        Divider()

        Button(role: .destructive) {
            service.delete(id: playlist.id)
        } label: {
            Label("Delete Smart Playlist", systemImage: "trash")
        }
    }

    /// The rule's current songs. Only songs with audio, so the queue doesn't stall.
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
