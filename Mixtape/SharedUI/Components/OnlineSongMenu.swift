// Context menu for a song found online. Anything that needs a library row
// (favourite, add to playlist) saves the song first.
// Left out: Remove from Library, Save a File Copy, Move to Artist Folder. They
// act on a file; once saved, the check button opens the removal panel.
// ponytail: add them if a Discover row ever becomes a library row.

import SwiftUI

struct OnlineSongMenu: View {

    let song: OnlineTrack
    let onPlay:       () -> Void
    /// True when this song is playing, since `onPlay` toggles.
    var isPlaying:    Bool = false
    /// Nil where there's no queue to act on.
    var onPlayNext:   (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    /// Forgets the cached source and re-resolves.
    var onWrongVersion: (() -> Void)? = nil
    /// Open the song's album / one of its artists in Discover. Nil drops the item.
    var onOpenAlbum:  (() -> Void)?       = nil
    var onOpenArtist: ((String) -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    #if os(macOS)
    @EnvironmentObject private var appState:    MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    var body: some View {
        Button(isPlaying ? "Pause" : "Play",
               systemImage: isPlaying ? "pause.fill" : "play.fill", action: onPlay)
        if let onPlayNext {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
        }
        if let onAddToQueue {
            Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
        }

        Divider()

        // Save, favourite, file: same order as the library menu. For an unsaved song
        // saving is favouriting (the like is what keeps it), so there's one item.
        if saved == nil {
            Button("Add to Liked Songs", systemImage: "heart") {
                Task { await coordinator.addToLibrary(song) }
                // The + button says this itself; from a menu nothing else would.
                deps.showSavedToast(.library)
            }
        } else if let track = saved, deps.libraryService.isFavourited(trackID: track.id) {
            Button("Remove from Liked Songs", systemImage: "heart.slash") {
                deps.toggleFavourite(trackID: track.id)
            }
        } else {
            // In a playlist or saved album but not liked.
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
                    // Several artists become a submenu.
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
            SongRadioMenuItem(song: song)
        }

        if onWrongVersion != nil || saved != nil {
            Divider()
            if let onWrongVersion {
                Button("Wrong Version? Re-resolve",
                       systemImage: "arrow.triangle.2.circlepath", action: onWrongVersion)
            }
            if let track = saved {
                Button("Get Info", systemImage: "info.circle") {
                    #if os(macOS)
                    appState.showInspector(for: track)
                    #else
                    iosAppState.showInfo(for: track)
                    #endif
                }
                DownloadMenuItems(track: track, downloads: deps.downloadManager)
            }
        }

        Divider()
        SuggestLessMenuItems(song: song)
        ShareMenuItems(.track(song))
    }

    // MARK: - Actions

    /// Favourite the song, saving it first if needed. One card
    /// (`.libraryAndFavourites`), not two. Adds rather than toggles, so an
    /// already-favourited song isn't unfavourited.
    private func favourite() {
        if let track = saved {
            deps.toggleFavourite(trackID: track.id)
            return
        }
        Task {
            await coordinator.addToLibrary(song)
            // Not `song.stableTrackID`: import may return an existing row with an older id.
            guard let track = saved else { return }
            deps.libraryService.addTrack(id: track.id, toPlaylist: Playlist.favouritesID)
            deps.showSavedToast(.libraryAndFavourites)
        }
    }

    /// Add to a playlist, saving first if needed. The card names the playlist either way.
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

    /// This song's library row: by id, then by recording. Same match as
    /// `SaveToLibraryButton`, so the two controls agree.
    private var saved: Track? {
        let byID = deps.libraryService.track(id: song.stableTrackID)
        let track = byID ?? deps.libraryService.track(matching: song.title,
                                                      artistName: song.artistName,
                                                      duration: song.duration)
        guard let track, !SavedAlbumsService.shared.albumOnlyIDs.contains(track.id) else { return nil }
        return track
    }

    /// Mixes and other people's playlists would reject the add, so they're excluded.
    private var playlistTargets: [Playlist] {
        deps.libraryService.playlists.filter {
            !$0.isAllSongs && !$0.isDeleted && $0.isEditable
        }
    }
}
