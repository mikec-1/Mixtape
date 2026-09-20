// PlaylistActionsMenu.swift
// Mixtape — SharedUI/Components
//
// Everything a playlist can do, in one list, wherever you right-click it.
//
// The playlist's own page has always had a "…" menu; a sidebar row had three
// items. That made the row's menu look like the short version of the real one,
// which is exactly what it was — so the way to send a playlist to Spotify was
// to open it first. This is the same list, reachable from the row.
//
// Deliberately self-contained: it takes a `Playlist` and reads its songs, its
// Spotify link and its published state off `deps`. A menu that needed the
// detail view's loaded state could only ever be shown on the detail view.

import SwiftUI

// MARK: - Presentation

/// The sheets the menu can open. Hosted by the modifier rather than the menu:
/// a `.contextMenu`'s content is torn down the moment it closes, so anything
/// presented from inside it would be dismissed along with the menu.
enum PlaylistActionSheet: Int, Identifiable {
    case edit, spotifyExport, collaborate
    var id: Int { rawValue }
}

// MARK: - The menu

struct PlaylistActionsMenu: View {

    let playlist: Playlist
    /// Every playlist the click applies to. One row for an ordinary right-click;
    /// the whole selection when the row that was clicked is part of it.
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

    /// Only what makes sense done to several playlists at once.
    ///
    /// Nothing else generalises: "Send to Spotify" over four playlists is four
    /// different review sheets, and "Edit Details" has one name field. Offering
    /// them greyed out would say they were coming; leaving them out says they
    /// are one-playlist actions, which is the truth.
    @ViewBuilder
    private var multiSelectionMenu: some View {
        // Songs are resolved inside the closure, never in the body: this menu
        // is rebuilt on every redraw of the row it hangs off, and walking the
        // whole selection's track lists there is the exact cost that made the
        // list stutter once before.
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

        // Pinning is only shown when the whole selection agrees, because there
        // is no honest label for a mixed one: "Pin 3 Playlists" over a set where
        // two are already pinned promises a change to all three.
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

        // System playlists can't be copied or thrown away, so they're dropped
        // from the count rather than silently skipped by an action that claimed
        // to cover them.
        if !editableIDs.isEmpty {
            Button {
                for id in editableIDs { _ = deps.libraryService.duplicatePlaylist(id: id) }
                deps.showToast("Duplicated \(editableIDs.count) playlist\(editableIDs.count == 1 ? "" : "s")")
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
        // Songs without audio behind them are left out for the same reason Play
        // leaves them out: a queue that stops dead partway through reads as a
        // broken player.
        Button {
            deps.onlineCoordinator.addToQueue(localTracks: playableTracks)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(isEmpty)

        Divider()

        // Offered on every playlist, system ones included: pinning Favourites to
        // the top is the default, not a rule.
        Button {
            meta.togglePin(playlistID: playlist.id)
        } label: {
            Label(isPinned ? "Unpin" : "Pin to Top",
                  systemImage: isPinned ? "pin.slash" : "pin")
        }

        Divider()

        spotifySyncSection

        if isReadOnly {
            // The one edit that is legitimately yours to make on someone else's
            // playlist: take a copy and do as you like with that.
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
                    deps.showToast("Duplicated as \u{201C}\(copy.name)\u{201D}")
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

            Divider()

            Button {
                present(.edit)
            } label: {
                Label("Edit Details", systemImage: "pencil")
            }

            // The way back to a composed cover.
            //
            // Deleting a cover in Edit Details now means "no picture" and is
            // left alone — the app used to answer that by putting the opening
            // track's artwork straight back, which reads as the deletion not
            // having worked. This is the same thing, asked for rather than
            // assumed, and it also refreshes a derived cover that has fallen
            // behind the songs it was made from.
            Button {
                deps.libraryService.generateDefaultCover(forPlaylist: live.id)
            } label: {
                Label("Generate Cover", systemImage: "square.grid.2x2")
            }
            .disabled(!deps.libraryService.canGenerateCover(forPlaylist: live.id))
        }

        // Not offered once the playlist is already linked: this would make a
        // *second* copy over there, next to the one it's being kept in step
        // with. The link's own section says what is happening instead.
        if deps.spotifyAuth.isAuthorized, !isEmpty, link == nil {
            Divider()
            Button {
                present(.spotifyExport)
            } label: {
                Label("Send to Spotify", systemImage: "arrow.up.forward.square")
            }
        }

        Divider()

        // Always offered, not just when something is visibly blank. A cover can
        // be present and wrong, and an item that only appears when a square is
        // grey can't fix that.
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
                // "Delete" overstates it for something you saved: the original is
                // untouched, and on a mix there is nothing to delete but your own
                // copy of it.
                Label(isReadOnly ? "Remove from Library" : "Delete Playlist",
                      systemImage: "trash")
            }
        }
    }

    // MARK: Spotify

    /// The same two switches the playlist's page offers, on any linked playlist
    /// whichever way it was set up.
    @ViewBuilder
    private var spotifySyncSection: some View {
        if let link {
            let isLiked = link.kind == .likedSongs

            // Buttons with an explicit icon rather than `Toggle`s: a menu toggle
            // draws its checkmark only when it's on, which shifts both labels
            // sideways as they change.
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
                // Liked Songs poured two thousand songs into Favourites and has
                // no playlist to delete afterwards, so stopping has to offer to
                // undo that too — see the dialog on the host.
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
            // Unlinking drops the link but not the songs it brought. Without
            // this the only control that removes them is on a dialog that only
            // a live link can open, so stopping the sync first stranded them.
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

    /// Both switches off means there is nothing left to sync, which is what
    /// unlinking is. Nothing is deleted either way.
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

    /// Deliberately not `tracks.isEmpty`. Everything on this menu is built for
    /// every row that can be right-clicked, so resolving a playlist's songs in
    /// here means resolving every playlist's songs on every redraw — which on a
    /// library-sized All Songs is what froze the list. Ids are enough to know
    /// whether there is anything to act on; the songs themselves are looked up
    /// when an item is actually pressed.
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
        deps.showToast("Copied \u{201C}\(source.name)\u{201D} to your library")
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

    /// Your own published covers first, then the catalogue Discover searches.
    /// Results are written to the track, so this is a repair rather than a fetch
    /// that has to happen on every launch.
    private func refetchCovers() async {
        await refetchCovers(in: [live.id])
    }

    /// Covers for every song in `playlistIDs`, de-duplicated — two selected
    /// playlists sharing a song must not fetch that song's cover twice.
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
        deps.showToast(updated == 0
                       ? "Covers are up to date"
                       : "Updated \(updated) cover\(updated == 1 ? "" : "s")")
    }
}

// MARK: - Host

/// Attaches the menu to a row, and owns everything the menu can open.
///
/// The sheets and dialogs live here rather than inside the menu because a
/// `.contextMenu`'s content disappears with the menu — a sheet presented from
/// in there would be dismissed the moment it was asked for.
private struct PlaylistActionsModifier: ViewModifier {

    let playlist: Playlist
    /// The rows currently selected. Used only when this row is one of them:
    /// right-clicking outside a selection acts on the row you clicked, exactly
    /// as it does in Finder.
    let selection: Set<UUID>

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif

    @State private var sheet: PlaylistActionSheet?

    /// What a confirmation dialog needs to draw itself, worked out once when the
    /// menu item is pressed.
    ///
    /// SwiftUI evaluates a `confirmationDialog`'s title, actions and message on
    /// every body pass, presented or not — so counting the songs a delete would
    /// take, or how many rows Spotify put in Favourites, ran once per playlist
    /// row per redraw. Those are library-wide scans. Holding the answers here
    /// means the scan happens on the click that asked for it.
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

    /// The playlists a delete would actually take. System rows are dropped
    /// rather than refused: the menu already left them out of the count.
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
                    // No `.frame(minWidth:)` wrapper — MixSheet sizes itself,
                    // and a wrapper sets the window to its own number while the
                    // chrome inside stays at the size class's.
                    SpotifyExportView(playlistName: live.name,
                                      tracks: songs(of: live),
                                      playlistID: live.id)
                        .environmentObject(deps)
                case .collaborate:
                    InviteCollaboratorsSheet(playlist: live, tracks: songs(of: live))
                        .environmentObject(deps)
                }
            }
            .confirmationDialog(deleteRequest?.title ?? "",
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
            .confirmationDialog(stopLikedRequest?.isLinked == false
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
                        // The import is gone, so "Imported" must stop standing
                        // over it in the picker.
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
        // Per-playlist teardown first, then a single library delete for the
        // whole selection: `deletePlaylists` scans the library once for the
        // batch, where a loop of `delete(id)` scanned it once per playlist.
        var plain: [UUID] = []
        for id in targets where tearDown(id) { plain.append(id) }
        deps.libraryService.deletePlaylists(ids: plain)
        #if os(macOS)
        if let open = appState.selectedPlaylist, targets.contains(open.id) {
            appState.selectedPlaylist = nil
        }
        appState.clearPlaylistSelection()
        #endif
    }

    /// The same teardown the playlist's own page performs, because a playlist
    /// deleted from a row leaves the same things behind: a published row on a
    /// profile, a Spotify link that would resurrect it on the next sync, and a
    /// follow of someone else's playlist.
    /// Returns true when the playlist still needs deleting from the library —
    /// false when un-following it has already taken the local copy with it.
    @discardableResult
    private func tearDown(_ id: UUID) -> Bool {
        guard let target = deps.libraryService.playlist(id: id) else { return false }

        // Owners only. A collaborator deleting their copy is leaving the
        // playlist, not ending it — the row isn't theirs to take down.
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
    /// The full playlist menu on a right-click (long-press on iOS).
    ///
    /// `selection` is the set of rows currently picked; pass it where the
    /// surface has one, and the menu switches to the multi-playlist form when
    /// the clicked row is inside it.
    func playlistActions(_ playlist: Playlist, selection: Set<UUID> = []) -> some View {
        modifier(PlaylistActionsModifier(playlist: playlist, selection: selection))
    }
}
