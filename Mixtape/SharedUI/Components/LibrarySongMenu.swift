// LibrarySongMenu.swift
// Mixtape — SharedUI/Components
//
// The right-click menu for a song the library holds — the counterpart to
// `OnlineSongMenu`, and the menu that used to be hand-written in eight places.
//
// Every copy agreed on what a song menu is for and disagreed on the details:
// Home offered no download, the queue offered no playlists, the artist page
// offered no "Go to Album", and only the playlist page knew what to do with a
// selection of more than one row. None of that was a decision — it was the same
// menu written eight times from memory. What genuinely differs by surface (what
// Play means here, what Remove removes) is a parameter; everything else is the
// same everywhere, which is why it lives here.
//
// A `.contextMenu`'s content is torn down the moment it closes, so an item that
// wants a sheet hands the request up to the surface instead
// (`onChoosePlaylist`, `onRemove`) and an ancestor hosts the sheet.

import SwiftUI

struct LibrarySongMenu: View {

    /// The row that was right-clicked, or the whole selection when that row is
    /// inside it. One song reads exactly as it always did; several are counted,
    /// so nothing ever acts on more rows than the wording admits to.
    let targets: [Track]
    let onPlay: () -> Void

    /// Queued one song at a time, so the surface only has to say how *one* song
    /// gets there. Nil uses the engine's own queue, which is what every surface
    /// but the mix page wants — a mix row has to be resolved online first.
    var onPlayNext:   ((Track) -> Void)? = nil
    var onAddToQueue: ((Track) -> Void)? = nil

    /// Opens the full "Add to Playlist" sheet — the only way to reach a playlist
    /// that doesn't exist yet, and on a selection the only place that shows
    /// which playlists already hold part of it. Nil leaves just the inline list.
    var onChoosePlaylist: (([Track]) -> Void)? = nil

    /// The destructive item at the bottom, named by what the song is leaving:
    /// "Playlist", "Library", "Queue". Both of these are supplied or neither is.
    var removeFrom: String? = nil
    var onRemove:   (([Track]) -> Void)? = nil

    /// Writes a real file into the user's export folder. Nil drops the item —
    /// download and file copy are two separate wishes and neither implies the
    /// other, so a surface can offer the first without the second.
    var onSaveToDisk: (([Track]) -> Void)? = nil

    /// The page a song is already on has nothing to go to.
    var showsGoToArtist = true
    var showsGoToAlbum  = true
    /// Nil falls back to Discover's album page on macOS. iOS has no app-wide
    /// album route, so a surface that wants the item there supplies its own.
    var onOpenAlbum: (() -> Void)? = nil


    /// A surface holding the catalogue copy of these rows saves them better than
    /// this menu can: rebuilding an online form from a display row throws away
    /// the resolved source, which is how a mix row comes back as a different
    /// version of the song. Saving is also what liking and filing do first, so a
    /// surface that supplies one of these supplies all three.
    var onAddToLibrary:  (([Track]) -> Void)?       = nil
    var onToggleLike:    ((Track) -> Void)?         = nil
    var onAddToPlaylist: (([Track], UUID) -> Void)? = nil
    /// Same reason: a display row has no stored artwork, so the share card it
    /// builds comes out blank. A surface holding the catalogue copy shares that.
    var shareItem: ShareItem? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    #if os(macOS)
    @EnvironmentObject private var appState:    MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    var body: some View {
        // A collaborator's own file, which this device can't get hold of. Play is
        // still offered — the engine sends anything with no local audio to the
        // online resolver, and a song someone ripped is often a song that also
        // exists online — but queueing it isn't, because a queue that stops dead
        // partway through reads as a broken player rather than a missing song.
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
                // Reversed: each insert goes directly after the current song, so
                // pushing them in back-to-front is what leaves the selection in
                // the queue in the order it appears on screen.
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

        // Navigation and Get Info answer a question about one song, so they only
        // appear when there is one song to ask about.
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
                    // In the library only because its album is saved. Same rule
                    // and same word as `OnlineSongMenu`: liking it is what
                    // promotes it out of the album, so this is one item, not two.
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
                // A queue or history row: a display mirror of a Discover song
                // that was played but never kept. A favourite is a flag on a
                // library row, so there is nothing yet to flag.
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
            // "Remove" only when every one of them is already a favourite —
            // otherwise the item fills the gaps, which is the wish behind
            // favouriting a mixed selection.
            let favoured = playable.allSatisfy { deps.libraryService.isFavourited(trackID: $0.id) }
            Button(label(favoured ? "Remove from Liked Songs" : "Add to Liked Songs", playable,
                         plural: favoured ? "Remove \(playable.count) from Liked Songs"
                                          : "Add \(playable.count) to Liked Songs"),
                   systemImage: favoured ? "heart.slash" : "heart") {
                // Straight through the service, then one card: routing a
                // selection through `deps.toggleFavourite` would stack twenty
                // identical cards for one menu tap.
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

    /// Mixes and saved playlists are excluded as *targets* as well: they're in
    /// the list like any other playlist, and an "Add to Playlist" that quietly
    /// did nothing would be the worst version of read-only. A playlist already
    /// holding every selected song drops out for the same reason.
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

    /// The two navigation items every track row offers. Features are split, so a
    /// track credited to "A feat. B" offers both artists rather than guessing.
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
        // The Discover artist page, the same as macOS and the same as tapping
        // the name in a row: the local page only holds what you saved.
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

    /// Opens Discover with this song's title and artist already searched, so a
    /// placeholder can be turned into the real thing in two taps.
    ///
    /// The query is filed with the session store *and* fired directly rather
    /// than left to the Discover view's `onChange`. On iOS that view may not
    /// exist yet — a tab never opened this launch has nothing to observe the
    /// change — and the search would arrive at a view that isn't there.
    private func findInDiscover(_ track: Track) {
        let query = [track.title, track.artistName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return }

        let store = DiscoverSessionStore.shared
        // Land on the results rather than on whatever page Discover was last
        // drilled into.
        store.path.removeAll()

        #if os(macOS)
        // Order matters: `searchText` writes into whichever corpus the current
        // selection names, so selecting Discover first is what stops the query
        // being filed under — and applied to — the library's search box.
        appState.selection  = .discover
        appState.searchText = query
        // The user asked for this search by name, so it lands committed —
        // writing the text alone would only arm the suggestions panel.
        appState.showSearchResults()
        #else
        store.iosQuery = query
        iosAppState.selectedTab = .discover
        #endif

        store.search(query, using: deps.itunesClient, immediate: true)
    }

    // MARK: - Downloads

    /// Two separate wishes, two separate items: "Download" keeps the song
    /// playable with no network, "file copy" puts a real file in the export
    /// folder. Neither implies the other.
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

    /// Files the songs, saving any the library doesn't hold yet — a queue row or
    /// a history card is often a Discover song that was never kept, and a
    /// playlist can only hold library rows.
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

    /// Likes the song — through the surface's own route when it has one, since
    /// a song the library doesn't hold has to be saved before it can be flagged.
    private func like(_ track: Track, row: Track) {
        if let onToggleLike { onToggleLike(track) } else { deps.toggleFavourite(trackID: row.id) }
    }

    /// The library's own row for `track`, which isn't always the row the display
    /// copy claims: the import hashes the resolved file, so a song that was just
    /// saved comes back under the file's id rather than the card's. Matched the
    /// way `OnlineSongMenu` matches, for the same reason.
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
