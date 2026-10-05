// Every playlist action in one menu, used by the detail page's "..." and row
// right-clicks. Takes a `Playlist` and reads everything else off `deps`, so
// it works anywhere.

import SwiftUI

// MARK: - Presentation

/// Sheets the menu can open. Hosted by the modifier, since a context menu's
/// content is torn down on close.
enum PlaylistActionSheet: Int, Identifiable {
    case edit, spotifyExport, collaborate, dub
    var id: Int { rawValue }
}

// MARK: - The menu

struct PlaylistActionsMenu: View {

    let playlist: Playlist
    /// The clicked row, or the selection if it's inside it.
    let ids: [UUID]
    let present: (PlaylistActionSheet) -> Void
    let confirmDelete: () -> Void
    let confirmStopLikedSongs: () -> Void

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var meta = PlaylistMetadataService.shared

    var body: some View {
        if ids.count > 1 {
            multiSelectionMenu
        } else {
            singlePlaylistMenu
        }
    }

    // MARK: Many playlists

    /// Only what applies to several playlists at once. The rest are one-playlist
    /// actions and are left out rather than greyed out.
    @ViewBuilder
    private var multiSelectionMenu: some View {
        // Songs are resolved in the closure, never in the body; the menu rebuilds
        // with its row.
        Button {
            let tracks = ids.flatMap { id in
                (deps.libraryService.playlist(id: id)?.trackIDs ?? [])
                    .compactMap { deps.libraryService.track(id: $0) }
            }
            .filter(\.canResolveAudio)
            deps.onlineCoordinator.addToQueue(localTracks: tracks)
        } label: {
            Label("Add \(ids.count) Playlists to Queue", systemImage: "text.append")
        }

        Divider()

        // Pin only when the whole selection agrees; a mixed set has no honest label.
        if allPinned {
            Button {
                for id in ids where meta.isPinned(playlistID: id) { meta.togglePin(playlistID: id) }
            } label: {
                Label("Unpin \(ids.count) Playlists", systemImage: "pin.slash")
            }
            Divider()
        } else if allUnpinned {
            Button {
                for id in ids where !meta.isPinned(playlistID: id) { meta.togglePin(playlistID: id) }
            } label: {
                Label("Pin \(ids.count) Playlists", systemImage: "pin")
            }
            Divider()
        }

        // System playlists can't be copied or deleted, so they're left out of the count.
        if !editableIDs.isEmpty {
            Button {
                for id in editableIDs { _ = deps.libraryService.duplicatePlaylist(id: id) }
                deps.showToast(.done("Duplicated \(editableIDs.count) playlist\(editableIDs.count == 1 ? "" : "s")"))
            } label: {
                Label("Duplicate \(editableIDs.count) Playlist\(editableIDs.count == 1 ? "" : "s")",
                      systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Label("Delete \(editableIDs.count) Playlist\(editableIDs.count == 1 ? "" : "s")",
                      systemImage: "trash")
            }
        }

        Divider()

        Button {
            Task { await refetchCovers(in: ids) }
        } label: {
            Label("Refetch All Covers", systemImage: "photo.badge.arrow.down")
        }
    }

    private var allPinned:    Bool { ids.allSatisfy { meta.isPinned(playlistID: $0) } }
    private var allUnpinned:  Bool { ids.allSatisfy { !meta.isPinned(playlistID: $0) } }
    private var editableIDs:  [UUID] {
        ids.filter { id in
            guard let p = deps.libraryService.playlist(id: id) else { return false }
            return !p.isSystem
        }
    }

    // MARK: One playlist

    @ViewBuilder
    private var singlePlaylistMenu: some View {
        // Only songs with audio, so the queue doesn't stall.
        Button {
            deps.onlineCoordinator.addToQueue(localTracks: playableTracks)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(isEmpty)

        Divider()

        // On every playlist, system ones included.
        Button {
            meta.togglePin(playlistID: playlist.id)
        } label: {
            Label(isPinned ? "Unpin" : "Pin to Top",
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
        if !playlist.isSystem {
            AddToCrateMenu(item: .playlist(playlist.id))
        }

        Divider()

        spotifySyncSection

        if isReadOnly {
            // Someone else's playlist can still be copied.
            Button {
                makeEditableCopy()
            } label: {
                Label("Make a Copy", systemImage: "doc.on.doc")
            }
            .disabled(isEmpty)
            PlaylistShareMenuItems(playlist: live)

            Divider()
        } else if !live.isSystem {
            Button {
                if let copy = deps.libraryService.duplicatePlaylist(id: playlist.id) {
                    deps.showToast(Toast.done("Duplicated as \u{201C}\(copy.name)\u{201D}").action("View") { Toast.openPlaylist(copy.id) })
                }
            } label: {
                Label("Duplicate Playlist", systemImage: "doc.on.doc")
            }

            Button {
                setPublic(!isPublic)
            } label: {
                Label(isPublic ? "Hide from My Profile" : "Show on My Profile",
                      systemImage: isPublic ? "eye.slash" : "person.crop.circle")
            }
            .disabled(deps.authService.currentUser == nil)

            Button {
                present(.collaborate)
            } label: {
                Label("Invite Collaborators", systemImage: "person.badge.plus")
            }
            PlaylistShareMenuItems(playlist: live)
            Button {
                present(.dub)
            } label: {
                Label("Dub for Someone\u{2026}", systemImage: "recordingtape")
            }
            .disabled(deps.authService.currentUser == nil || isEmpty)

            Divider()

            Button {
                present(.edit)
            } label: {
                Label("Edit Details", systemImage: "pencil")
            }

            // Rebuild the composed cover. Deleting a cover in Edit Details means "no
            // picture"; this asks for the derived one back, and refreshes a stale one.
            Button {
                deps.libraryService.generateDefaultCover(forPlaylist: live.id)
            } label: {
                Label("Generate Cover", systemImage: "square.grid.2x2")
            }
            .disabled(!deps.libraryService.canGenerateCover(forPlaylist: live.id))
        }

        // Not once linked: it would make a second copy on Spotify.
        if deps.spotifyAuth.isAuthorized, !isEmpty, link == nil {
            Divider()
            Button {
                present(.spotifyExport)
            } label: {
                Label("Send to Spotify", systemImage: "arrow.up.forward.square")
            }
        }

        Divider()

        // Always offered: a cover can be present and wrong.
        Button {
            Task { await refetchCovers() }
        } label: {
            Label("Refetch All Covers", systemImage: "photo.badge.arrow.down")
        }
        .disabled(isEmpty)

        if !live.isSystem {
            Divider()
            Button(role: .destructive) {
                confirmDelete()
            } label: {
                // Saved playlists are removed, not deleted; the original is untouched.
                Label(isReadOnly ? "Remove from Library" : "Delete Playlist",
                      systemImage: "trash")
            }
        }
    }

    // MARK: Spotify

    /// Same two sync switches as the playlist page, on any linked playlist.
    @ViewBuilder
    private var spotifySyncSection: some View {
        if let link {
            let isLiked = link.kind == .likedSongs

            // Buttons with icons, not `Toggle`s: a menu toggle's checkmark shifts the labels.
            Button {
                setSyncDirection(pushes: !link.direction.pushes, pulls: link.direction.pulls)
            } label: {
                Label(isLiked ? "Add New Likes to Spotify" : "Send Changes to Spotify",
                      systemImage: link.direction.pushes ? "checkmark.circle.fill" : "circle")
            }

            Button {
                setSyncDirection(pushes: link.direction.pushes, pulls: !link.direction.pulls)
            } label: {
                Label(isLiked ? "Bring Liked Songs from Spotify" : "Bring Changes from Spotify",
                      systemImage: link.direction.pulls ? "checkmark.circle.fill" : "circle")
            }

            Divider()

            Button {
                Task { await deps.spotifyFollowService.sync(playlistID: playlist.id, force: true) }
            } label: {
                Label(isSyncing ? "Syncing\u{2026}" : "Sync Now",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)

            if let url = URL(string: isLiked
                             ? "https://open.spotify.com/collection/tracks"
                             : "https://open.spotify.com/playlist/\(link.sourceID)") {
                Button {
                    SpotifyAppLink.open(url)
                } label: {
                    Label("Open in Spotify", systemImage: "arrow.up.forward.app")
                }
            }

            Button {
                // Liked Songs has no playlist to delete, so stopping offers to undo its
                // Favourites import (see the host's dialog).
                if isLiked {
                    confirmStopLikedSongs()
                } else {
                    deps.spotifyFollowService.unlink(playlistID: playlist.id)
                }
            } label: {
                Label(isLiked ? "Stop Syncing with Liked Songs" : "Stop Syncing with Spotify",
                      systemImage: "link.badge.plus")
            }

            Divider()
        } else if deps.spotifyFollowService.contributionCount(playlistID: playlist.id) > 0 {
            // Unlinking keeps the songs it brought; this removes them.
            Button(role: .destructive) {
                confirmStopLikedSongs()
            } label: {
                Label("Remove Songs Imported from Spotify", systemImage: "trash")
            }

            Divider()
        }
    }

    private var link: SpotifyFollowService.Link? {
        deps.spotifyFollowService.link(forPlaylist: playlist.id)
    }

    private var isSyncing: Bool {
        deps.spotifyFollowService.syncing.contains(playlist.id)
    }

    /// Both off = unlink. Nothing is deleted either way.
    private func setSyncDirection(pushes: Bool, pulls: Bool) {
        let service = deps.spotifyFollowService
        switch (pushes, pulls) {
        case (true, true):   service.setDirection(.both, forPlaylist: playlist.id)
        case (true, false):  service.setDirection(.push, forPlaylist: playlist.id)
        case (false, true):  service.setDirection(.pull, forPlaylist: playlist.id)
        case (false, false): service.unlink(playlistID: playlist.id)
        }
    }

    // MARK: Derived

    private var live: Playlist { deps.libraryService.playlist(id: playlist.id) ?? playlist }
    private var isPinned: Bool { meta.isPinned(playlistID: playlist.id) }
    private var isReadOnly: Bool { !live.isEditable }
    private var isPublic: Bool {
        PlaylistSharingService.shared.isPublicCached(localPlaylistID: playlist.id)
    }

    /// Checks ids, not `tracks`: this runs for every row on every redraw.
    /// Songs are looked up only when an item is pressed.
    private var isEmpty: Bool { live.trackIDs.isEmpty }

    private var tracks: [Track] {
        live.trackIDs.compactMap { deps.libraryService.track(id: $0) }
    }
    private var playableTracks: [Track] { tracks.filter(\.canResolveAudio) }

    // MARK: Actions

    private func makeEditableCopy() {
        let source = live
        guard !source.trackIDs.isEmpty else { return }
        let copy = deps.libraryService.createPlaylist(name: source.name,
                                                      description: source.description,
                                                      artworkData: source.displayArtwork)
        deps.libraryService.setTracks(source.trackIDs, inPlaylist: copy.id)
        deps.showToast(Toast.done("Copied \u{201C}\(source.name)\u{201D} to your library")
            .action("View") { Toast.openPlaylist(copy.id) })
    }

    private func setPublic(_ value: Bool) {
        let snapshot = live
        let songs = tracks
        Task {
            try? await PlaylistSharingService.shared.setPublic(
                value,
                playlist: snapshot,
                tracks: songs,
                deviceID: AppDependencies.deviceID
            )
        }
    }

    /// Own published covers first, then the Discover catalogue. Written to the track.
    private func refetchCovers() async {
        await refetchCovers(in: [live.id])
    }

    /// Covers for all songs in `playlistIDs`, de-duplicated.
    private func refetchCovers(in playlistIDs: [UUID]) async {
        var seen = Set<UUID>()
        let ids = playlistIDs
            .flatMap { deps.libraryService.playlist(id: $0)?.trackIDs ?? [] }
            .filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        deps.showToast("Refetching \(ids.count) cover\(ids.count == 1 ? "" : "s")\u{2026}")
        let updated = await deps.libraryService.backfillPlaceholderArtwork(
            trackIDs:          ids,
            publishedBy:       deps.authService.currentUser?.id,
            using:             deps.itunesClient,
            replacingExisting: true
        )
        deps.showToast(.done(updated == 0
                             ? "Covers are up to date"
                             : "Updated \(updated) cover\(updated == 1 ? "" : "s")"))
    }
}

// MARK: - Host

/// Attaches the menu to a row and hosts what it opens (a context menu's content
/// disappears with the menu).
private struct PlaylistActionsModifier: ViewModifier {

    let playlist: Playlist
    /// Used only when this row is in the selection, like Finder.
    let selection: Set<UUID>

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif

    @State private var sheet: PlaylistActionSheet?

    /// Dialog contents worked out once when the item is pressed.
    /// `confirmationDialog` evaluates its title and message every body pass,
    /// presented or not, so library-wide counts there ran per row per redraw.
    @State private var deleteRequest: DeleteRequest?
    @State private var stopLikedRequest: StopLikedRequest?

    struct DeleteRequest {
        var ids: [UUID]
        var title: String
        var confirmLabel: String
        var message: String
    }

    struct StopLikedRequest {
        var contributions: Int
        var isLinked: Bool
    }

    private var ids: [UUID] {
        selection.count > 1 && selection.contains(playlist.id)
            ? Array(selection)
            : [playlist.id]
    }

    /// System rows are dropped; the menu already left them out of the count.
    private var deletableIDs: [UUID] {
        ids.filter { id in
            guard let p = deps.libraryService.playlist(id: id) else { return false }
            return !p.isSystem
        }
    }

    private var live: Playlist { deps.libraryService.playlist(id: playlist.id) ?? playlist }
    private var isReadOnly: Bool { !live.isEditable }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                PlaylistActionsMenu(
                    playlist: playlist,
                    ids: ids,
                    present: { sheet = $0 },
                    confirmDelete: { deleteRequest = makeDeleteRequest() },
                    confirmStopLikedSongs: { stopLikedRequest = makeStopLikedRequest() }
                )
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .edit:
                    PlaylistEditorSheet(editingPlaylist: live)
                        .environmentObject(deps)
                case .spotifyExport:
                    // No `.frame(minWidth:)` wrapper; MixSheet sizes itself.
                    SpotifyExportView(playlistName: live.name,
                                      tracks: songs(of: live),
                                      playlistID: live.id)
                        .environmentObject(deps)
                case .collaborate:
                    InviteCollaboratorsSheet(playlist: live, tracks: songs(of: live))
                        .environmentObject(deps)
                case .dub:
                    DubSheet(playlist: live, tracks: songs(of: live))
                        .environmentObject(deps)
                }
            }
            .mixConfirmationDialog(deleteRequest?.title ?? "",
                                isPresented: Binding(get: { deleteRequest != nil },
                                                     set: { if !$0 { deleteRequest = nil } }),
                                titleVisibility: .visible) {
                Button(deleteRequest?.confirmLabel ?? "Delete", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteRequest?.message ?? "")
            }
            .mixConfirmationDialog(stopLikedRequest?.isLinked == false
                                ? "Remove the songs Spotify put here?"
                                : "Stop syncing with Spotify's Liked Songs?",
                                isPresented: Binding(get: { stopLikedRequest != nil },
                                                     set: { if !$0 { stopLikedRequest = nil } }),
                                titleVisibility: .visible) {
                let contributions = stopLikedRequest?.contributions ?? 0
                if stopLikedRequest?.isLinked != false {
                    Button("Stop Syncing and Keep Songs") {
                        deps.spotifyFollowService.unlink(playlistID: playlist.id)
                    }
                }
                if contributions > 0 {
                    Button("Remove the \(contributions) Imported Songs", role: .destructive) {
                        deps.spotifyFollowService.unlinkRemovingImports(playlistID: playlist.id)
                        // The import is gone, so drop the "Imported" badge.
                        deps.spotifyImportLedger.forget(playlistID: playlist.id)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text((stopLikedRequest?.contributions ?? 0) > 0
                     ? "Removes only the \(stopLikedRequest?.contributions ?? 0) songs that came from Spotify. Nothing on Spotify changes."
                     : "Nothing here came from Spotify, so nothing will be removed.")
            }
    }

    private func makeStopLikedRequest() -> StopLikedRequest {
        StopLikedRequest(
            contributions: deps.spotifyFollowService.contributionCount(playlistID: playlist.id),
            isLinked: deps.spotifyFollowService.isFollowing(playlistID: playlist.id))
    }

    private func songs(of playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { deps.libraryService.track(id: $0) }
    }

    // MARK: Delete

    /// Everything the dialog will say, counted once, on the press.
    private func makeDeleteRequest() -> DeleteRequest {
        let targets = deletableIDs
        let many    = targets.count > 1
        let songs   = targets.reduce(0) {
            $0 + deps.libraryService.songCountRemovedWithPlaylist(id: $1)
        }
        return DeleteRequest(
            ids: targets,
            title: many
                ? "Delete \(targets.count) playlists?"
                : PlaylistDeletionPrompt.title(name: live.name, isReadOnly: isReadOnly),
            confirmLabel: many
                ? "Delete \(targets.count) Playlists"
                : PlaylistDeletionPrompt.confirmLabel(isReadOnly: isReadOnly),
            message: PlaylistDeletionPrompt.message(songCount: songs,
                                                    isReadOnly: many ? false : isReadOnly)
        )
    }

    private func performDelete() {
        let targets = deleteRequest?.ids ?? deletableIDs
        // Teardown per playlist, then one library delete for the batch (one scan).
        var plain: [UUID] = []
        for id in targets where tearDown(id) { plain.append(id) }
        SupabaseSyncService.allowBulk("delete-playlists")
        deps.libraryService.deletePlaylists(ids: plain)
        #if os(macOS)
        if let open = appState.selectedPlaylist, targets.contains(open.id) {
            appState.selectedPlaylist = nil
        }
        appState.clearPlaylistSelection()
        #endif
    }

    /// Same teardown as the playlist page: published row, Spotify link (would
    /// resurrect it on sync) and a follow. Returns false when unfollowing already
    /// removed the local copy.
    @discardableResult
    private func tearDown(_ id: UUID) -> Bool {
        guard let target = deps.libraryService.playlist(id: id) else { return false }

        // Owners only; a collaborator deleting their copy is leaving, not ending it.
        if let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: id),
           link.role == PlaylistSharingService.Roles.owner {
            Task { try? await PlaylistSharingService.shared.deletePublished(sharedPlaylistID: link.sharedPlaylistID) }
        }
        if target.followsSpotify {
            deps.spotifyFollowService.unlink(playlistID: id)
        }
        if target.followsRemoteSource {
            PlaylistSharingService.shared.unsavePublicPlaylist(localPlaylistID: id,
                                                              libraryService: deps.libraryService)
            return false
        }
        return true
    }
}

extension View {
    /// Full playlist menu on right-click (long-press on iOS). Pass the surface's
    /// selection to get the multi-playlist form.
    func playlistActions(_ playlist: Playlist, selection: Set<UUID> = []) -> some View {
        modifier(PlaylistActionsModifier(playlist: playlist, selection: selection))
    }
}
