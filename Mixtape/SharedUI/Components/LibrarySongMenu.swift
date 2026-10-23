// Context menu for library songs (counterpart to `OnlineSongMenu`). Per-surface
// differences (what Play and Remove mean) are parameters.
// Items that need a sheet hand the request up, since menu content is torn
// down on close.

import SwiftUI

struct LibrarySongMenu: View {

    /// The clicked row, or the selection if it's inside it.
    let targets: [Track]
    let onPlay: () -> Void

    /// Nil uses the engine's queue; the mix page resolves online first.
    var onPlayNext:   ((Track) -> Void)? = nil
    var onAddToQueue: ((Track) -> Void)? = nil

    /// Opens the full sheet. Nil leaves just the inline list.
    var onChoosePlaylist: (([Track]) -> Void)? = nil

    /// "Playlist", "Library", "Queue". Both of these are supplied or neither is.
    var removeFrom: String? = nil
    var onRemove:   (([Track]) -> Void)? = nil

    /// Nil hides the item. Download and file copy are separate.
    var onSaveToDisk: (([Track]) -> Void)? = nil

    /// The page a song is already on has nothing to go to.
    var showsGoToArtist = true
    var showsGoToAlbum  = true
    /// Nil falls back to Discover's album page on macOS; iOS needs its own.
    var onOpenAlbum: (() -> Void)? = nil


    /// Surfaces with the catalogue copy save it better: rebuilding from a display
    /// row loses the resolved source. Supply all three or none.
    var onAddToLibrary:  (([Track]) -> Void)?       = nil
    var onToggleLike:    ((Track) -> Void)?         = nil
    var onAddToPlaylist: (([Track], UUID) -> Void)? = nil
    /// Display rows have no artwork, so the surface shares its catalogue copy.
    var shareItem: ShareItem? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator
    #if os(macOS)
    @Environment(MacAppState.self) private var appState
    #else
    @Environment(IOSAppState.self) private var iosAppState
    #endif

    var body: some View {
        // Unresolvable songs can still Play (the resolver may find them online) but
        // can't be queued.
        let playable = targets.filter(\.canResolveAudio)

        Button(label("Play Now", targets, plural: "Play \(targets.count) Songs"),
               systemImage: MixtapeIcons.play, action: onPlay)

        if targets.count == 1, let track = targets.first, !track.canResolveAudio {
            Button("Find in Discover", systemImage: "sparkle.magnifyingglass") {
                findInDiscover(track)
            }
        } else if !playable.isEmpty {
            Button(label("Play Next", playable, plural: "Play \(playable.count) Next"),
                   systemImage: "text.line.first.and.arrowtriangle.forward") {
                // Reversed so the selection keeps its order.
                let next = onPlayNext ?? { engine.queue.insertNext($0) }
                for song in playable.reversed() { next(song) }
            }
            Button(label("Add to Queue", playable, plural: "Add \(playable.count) to Queue"),
                   systemImage: "text.append") {
                let append = onAddToQueue ?? { engine.queue.append($0) }
                for song in playable { append(song) }
            }
        }

        Divider()
        saveItems(playable)
        playlistItems()

        // Navigation and Get Info only for a single song.
        if targets.count == 1, let track = targets.first {
            Divider()
            goToItems(for: track)
            ShareMenuItems(shareItem ?? .track(track))
            SuggestLessMenuItems(track: track)
            Button("Get Info", systemImage: "info.circle") {
                #if os(macOS)
                appState.showInspector(for: track)
                #else
                iosAppState.showInfo(for: track)
                #endif
            }
            // Songs the user brought in themselves: files and links.
            if track.origin == .imported {
                Button("Edit Metadata", systemImage: "pencil") {
                    #if os(macOS)
                    appState.enqueueReview(MetadataReviewItem(editing: track))
                    #else
                    iosAppState.enqueueReview(MetadataReviewItem(editing: track))
                    #endif
                }
            }
            if track.canEdit {
                Button("Edit Song…", systemImage: "slider.horizontal.3") {
                    #if os(macOS)
                    appState.editTrack = track
                    #else
                    iosAppState.editTrack = track
                    #endif
                }
            }
            if track.edit != nil {
                Button("Post…", systemImage: "paperplane") {
                    #if os(macOS)
                    appState.postTrack = track
                    #else
                    iosAppState.postTrack = track
                    #endif
                }
            }
        }

        if !playable.isEmpty {
            Divider()
            downloadItems(playable)
        }

        if let removeFrom, let onRemove {
            Divider()
            Button(label("Remove from \(removeFrom)", targets,
                         plural: "Remove \(targets.count) Songs from \(removeFrom)"),
                   role: .destructive) {
                onRemove(targets)
            }
        }
    }

    // MARK: - Saving and liking

    /// Which of "save it" and "like it" the song actually needs.
    @ViewBuilder
    private func saveItems(_ playable: [Track]) -> some View {
        if targets.count == 1, let track = targets.first {
            if let row = libraryRow(for: track) {
                if SavedAlbumsService.shared.albumOnlyIDs.contains(row.id) {
                    // In the library only via its album; liking promotes it. Matches `OnlineSongMenu`.
                    Button("Add to Liked Songs", systemImage: "heart") {
                        deps.toggleFavourite(trackID: row.id)
                    }
                } else {
                    let favoured = deps.libraryService.isFavourited(trackID: row.id)
                    Button(favoured ? "Remove from Liked Songs" : "Add to Liked Songs",
                           systemImage: favoured ? "heart.slash" : "heart") {
                        like(track, row: row)
                    }
                }
            } else {
                // Queue/history mirror of an unsaved Discover song.
                Button("Add to Liked Songs", systemImage: "heart") {
                    guard let onAddToLibrary else {
                        Task {
                            await coordinator.addToLibrary(unsaved: track)
                            deps.showSavedToast(.library)
                        }
                        return
                    }
                    onAddToLibrary([track])
                }
            }
        } else if !playable.isEmpty {
            // Remove only when all are favourites; otherwise fill the gaps.
            let favoured = playable.allSatisfy { deps.libraryService.isFavourited(trackID: $0.id) }
            Button(label(favoured ? "Remove from Liked Songs" : "Add to Liked Songs", playable,
                         plural: favoured ? "Remove \(playable.count) from Liked Songs"
                                          : "Add \(playable.count) to Liked Songs"),
                   systemImage: favoured ? "heart.slash" : "heart") {
                // Through the service, one card for the whole selection.
                let changed = playable.filter {
                    deps.libraryService.isFavourited(trackID: $0.id) == favoured
                }
                for song in changed { deps.libraryService.toggleFavourite(trackID: song.id) }
                if !favoured, !changed.isEmpty {
                    deps.showSavedToast(.favourites, count: changed.count)
                }
            }
        }
    }

    /// Read-only playlists and ones already holding every song are excluded.
    @ViewBuilder
    private func playlistItems() -> some View {
        let targetIDs = Set(targets.map(\.id))
        let lists = deps.libraryService.playlists.filter { pl in
            !pl.isAllSongs && !pl.isDeleted && pl.isEditable
                && !targetIDs.isSubset(of: Set(pl.trackIDs))
        }
        if !lists.isEmpty || onChoosePlaylist != nil {
            Menu {
                ForEach(lists) { pl in
                    Button(pl.name) { file(into: pl.id) }
                }
                if let onChoosePlaylist {
                    Divider()
                    Button("Choose Playlist\u{2026}") { onChoosePlaylist(targets) }
                }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
    }

    // MARK: - Navigation

    /// Go to artist/album. Features are split, so both artists are offered.
    @ViewBuilder
    private func goToItems(for track: Track) -> some View {
        if showsGoToArtist {
            let credits = ImportService.creditedArtists(from: track.artistName)
            if credits.count > 1 {
                Menu {
                    ForEach(credits, id: \.self) { name in
                        Button(name) { openArtist(named: name) }
                    }
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            } else if let name = credits.first, !name.isEmpty {
                Button("Go to Artist", systemImage: "music.mic") { openArtist(named: name) }
            }
        }
        if showsGoToAlbum, !track.albumTitle.isEmpty, let openAlbum = albumAction(for: track) {
            Button("Go to Album", systemImage: "square.stack", action: openAlbum)
        }
        SongRadioMenuItem(track: track)
    }

    private func openArtist(named name: String) {
        #if os(macOS)
        appState.openDiscoverArtist(named: name)
        #else
        // Discover artist page, same as macOS and tapping the name.
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    private func albumAction(for track: Track) -> (() -> Void)? {
        if let onOpenAlbum { return onOpenAlbum }
        #if os(macOS)
        return { appState.openDiscoverAlbum(for: track) }
        #else
        return nil
        #endif
    }

    /// Opens Discover with the song searched. Fired directly as well as stored,
    /// since on iOS the Discover view may not exist yet.
    private func findInDiscover(_ track: Track) {
        let query = [track.title, track.artistName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return }

        let store = DiscoverSessionStore.shared
        // Land on results, not a drilled-in page.
        store.path.removeAll()

        #if os(macOS)
        // Select Discover first; `searchText` writes into the current corpus.
        appState.selection  = .discover
        appState.searchText = query
        // Committed search, not just the suggestions panel.
        appState.showSearchResults()
        #else
        store.iosQuery = query
        iosAppState.selectedTab = .discover
        #endif

        store.search(query, using: deps.itunesClient, immediate: true)
    }

    // MARK: - Downloads

    /// Download (offline playback) and file copy (export folder) are separate.
    @ViewBuilder
    private func downloadItems(_ playable: [Track]) -> some View {
        if playable.count == 1, let track = playable.first {
            DownloadMenuItems(track: track, downloads: deps.downloadManager)
            if let onSaveToDisk {
                if deps.downloadManager.isExported(track.id) {
                    Button("Delete File Copy", systemImage: "trash") {
                        deps.downloadManager.deleteFileCopy(for: track.id)
                    }
                } else {
                    Button("Save a File Copy\u{2026}", systemImage: "square.and.arrow.down") {
                        onSaveToDisk([track])
                    }
                }
            }
        } else {
            BulkDownloadMenuItems(tracks: playable, downloads: deps.downloadManager)
            if let onSaveToDisk {
                Button("Save \(playable.count) File Copies\u{2026}",
                       systemImage: "square.and.arrow.down") {
                    onSaveToDisk(playable)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Saves missing songs first; playlists only hold library rows.
    private func file(into playlistID: UUID) {
        if let onAddToPlaylist { onAddToPlaylist(targets, playlistID); return }
        let unsaved = targets.filter { libraryRow(for: $0) == nil }
        guard !unsaved.isEmpty else {
            deps.addTracks(ids: targets.compactMap { libraryRow(for: $0)?.id },
                           toPlaylist: playlistID)
            return
        }
        Task {
            for track in unsaved { await coordinator.addToLibrary(unsaved: track) }
            deps.addTracks(ids: targets.compactMap { libraryRow(for: $0)?.id },
                           toPlaylist: playlistID)
        }
    }

    /// Through the surface's route when it has one, since unsaved songs need saving first.
    private func like(_ track: Track, row: Track) {
        if let onToggleLike { onToggleLike(track) } else { deps.toggleFavourite(trackID: row.id) }
    }

    /// The saved row can have a different id (import hashes the file), so match like
    /// `OnlineSongMenu` does.
    private func libraryRow(for track: Track) -> Track? {
        deps.libraryService.track(id: track.id)
            ?? deps.libraryService.track(matching: track.title,
                                         artistName: track.artistName,
                                         duration: track.duration)
    }

    /// Picks the singular or counted wording for a menu item.
    private func label(_ singular: String, _ items: [Track], plural: String) -> String {
        items.count > 1 ? plural : singular
    }
}
