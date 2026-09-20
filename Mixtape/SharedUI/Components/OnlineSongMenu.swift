// OnlineSongMenu.swift
// Mixtape — SharedUI/Components
//
// The right-click menu for a song that was found online.
//
// It used to be five items — play, play next, queue, add, share — against the
// fifteen a song in the library gets, which made a search result feel like a
// different and lesser kind of object. It isn't: the only true difference is
// that it hasn't been saved yet, and nearly every action that reads as missing
// (favourite it, file it in a playlist, go to the artist) is one that *implies*
// saving it. So they're all here, and the ones that need a library row save the
// song on their way through.
//
// Deliberately not here: Remove from Library, Save a File Copy, Move to Artist
// Folder. Those act on a file on disk, and the row you right-clicked is a search
// result — once the song is saved, its check button opens the panel that removes
// it. ponytail: add them if a Discover row ever wants to be a library row.

import SwiftUI

struct OnlineSongMenu: View {

    let song: OnlineTrack
    let onPlay:       () -> Void
    /// Nil where the surface genuinely has no queue to act on — the hero on a
    /// page that isn't a list.
    var onPlayNext:   (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    /// "This is the wrong version" — forgets the cached source and re-resolves.
    var onWrongVersion: (() -> Void)? = nil
    /// Open the song's album / one of its artists in Discover. Nil drops the item.
    var onOpenAlbum:  (() -> Void)?       = nil
    var onOpenArtist: ((String) -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    #if os(macOS)
    @EnvironmentObject private var appState:    MacAppState
    #endif

    var body: some View {
        Button("Play", systemImage: "play.fill", action: onPlay)
        if let onPlayNext {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
        }
        if let onAddToQueue {
            Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
        }

        Divider()

        // Saving, favouriting and filing, in the order the library's own menu
        // puts them: the plain wish first, then the more specific ones.
        //
        // One item, not two, for a song the library doesn't hold: saving it *is*
        // favouriting it now — a Discover row is metadata only, and the like is
        // the thing that keeps it. Offering both here would have been the same
        // action twice under two names.
        if saved == nil {
            Button("Add to Library", systemImage: "plus.circle") {
                Task { await coordinator.addToLibrary(song) }
                // The + button says this itself; from a menu nothing else would.
                deps.showSavedToast(.library)
            }
        } else if let track = saved, deps.libraryService.isFavourited(trackID: track.id) {
            Button("Remove from Liked Songs", systemImage: "heart.slash") {
                deps.toggleFavourite(trackID: track.id)
            }
        } else {
            // Held by a playlist or a saved album, but not liked — those are
            // still two different things once a song is in the library.
            Button("Add to Liked Songs", systemImage: "heart") { favourite() }
        }

        if !playlistTargets.isEmpty {
            Menu {
                ForEach(playlistTargets) { pl in
                    Button(pl.name) { file(into: pl.id) }
                }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }

        if onOpenArtist != nil || onOpenAlbum != nil {
            Divider()
            if let onOpenArtist {
                let names = song.displayArtists
                if names.count == 1 {
                    Button("Go to Artist", systemImage: "music.mic") { onOpenArtist(names[0]) }
                } else if names.count > 1 {
                    // A featured track has more than one artist to go to, so the
                    // item becomes a submenu instead of guessing at the primary.
                    Menu {
                        ForEach(names, id: \.self) { name in
                            Button(name) { onOpenArtist(name) }
                        }
                    } label: {
                        Label("Go to Artist", systemImage: "music.mic")
                    }
                }
            }
            if let onOpenAlbum, !song.albumTitle.isEmpty {
                Button("Go to Album", systemImage: "square.stack", action: onOpenAlbum)
            }
        }

        if onWrongVersion != nil || saved != nil {
            Divider()
            if let onWrongVersion {
                Button("Wrong Version? Re-resolve",
                       systemImage: "arrow.triangle.2.circlepath", action: onWrongVersion)
            }
            if let track = saved {
                #if os(macOS)
                Button("Get Info", systemImage: "info.circle") { appState.showInspector(for: track) }
                #endif
                DownloadMenuItems(track: track, downloads: deps.downloadManager)
            }
        }

        Divider()
        ShareMenuItems(.track(song))
    }

    // MARK: - Actions

    /// Favourite the song, saving it first if it isn't saved.
    ///
    /// One card, not two: the pill shows one message at a time, so a save
    /// followed by a favourite would show "Added to Library" for the instant it
    /// took the favourite to land and then replace it. `.libraryAndFavourites`
    /// is what actually happened, said once.
    ///
    /// Adds to the Favourites playlist rather than toggling it — this arm only
    /// runs for a song that isn't favourited, and a toggle on a song that turns
    /// out to have been saved and favourited already would take it back off.
    private func favourite() {
        if let track = saved {
            deps.toggleFavourite(trackID: track.id)
            return
        }
        Task {
            await coordinator.addToLibrary(song)
            // Not `song.stableTrackID`: the import hashes the resolved file, and
            // a file the library already has comes back under its older id.
            guard let track = saved else { return }
            deps.libraryService.addTrack(id: track.id, toPlaylist: Playlist.favouritesID)
            deps.showSavedToast(.libraryAndFavourites)
        }
    }

    /// File the song in a playlist, saving it first if it isn't saved. The
    /// playlist add announces itself, so the card names the playlist either way.
    private func file(into playlistID: UUID) {
        if let track = saved {
            deps.addTrack(id: track.id, toPlaylist: playlistID)
            return
        }
        Task {
            await coordinator.addToLibrary(song)
            guard let track = saved else { return }
            deps.addTrack(id: track.id, toPlaylist: playlistID)
        }
    }

    // MARK: - State

    /// This song's library row, if it has one.
    ///
    /// Matched the way `SaveToLibraryButton` matches — by id, then by recording
    /// — because the two controls sit on the same row and must not disagree
    /// about whether the song is saved. See that file for why the id alone
    /// isn't enough.
    private var saved: Track? {
        let byID = deps.libraryService.track(id: song.stableTrackID)
        let track = byID ?? deps.libraryService.track(matching: song.title,
                                                      artistName: song.artistName,
                                                      duration: song.duration)
        guard let track, !SavedAlbumsService.shared.albumOnlyIDs.contains(track.id) else { return nil }
        return track
    }

    /// The playlists a song can actually be added to — a mix or someone else's
    /// playlist would take the songs, fail the guard in `LibraryService` and
    /// look like nothing happened.
    private var playlistTargets: [Playlist] {
        deps.libraryService.playlists.filter {
            !$0.isAllSongs && !$0.isDeleted && $0.isEditable
        }
    }
}
