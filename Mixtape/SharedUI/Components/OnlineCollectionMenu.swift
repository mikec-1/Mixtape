// OnlineCollectionMenu.swift
// Mixtape — SharedUI/Components
//
// The right-click menu for an album, artist or mix found online.
//
// `AlbumActionsMenu` and `ArtistActionsMenu` read their songs out of the
// library, so on a Discover card for a record you don't own every item would
// have done nothing. These cards had one or two items instead — Play, Open,
// Share — against the nine a library album gets. The songs are a fetch here,
// not a lookup, so each item loads them when it's picked: through the same
// session cache the detail page uses, so opening the page afterwards is free.
//
// Deliberately not here:
//   * "Open …" — tapping the card already does that.
//   * Get Info — the detail page is this collection's information.
//   * Library and Download for an artist — an artist isn't a thing the library
//     holds, and downloading one would save top tracks nobody asked to keep.
//   * Remove for a saved mix — the mix page doesn't offer it either; once kept
//     it's a playlist, and the playlist's own menu deletes it.
//   * Download for an unsaved mix — the page only offers it once it's kept.

import SwiftUI

struct OnlineCollectionMenu: View {

    enum Collection {
        case album(OnlineAlbum)
        case artist(OnlineArtist)
        case mix(PersonalMix)
    }

    let collection: Collection
    /// Off in a page's "…", which sits beside that page's own Share button.
    let showsShare: Bool
    init(_ collection: Collection, showsShare: Bool = true) {
        self.collection = collection
        self.showsShare = showsShare
    }

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @ObservedObject private var savedAlbums = SavedAlbumsService.shared

    var body: some View {
        if !isEmptyMix {
            Button("Play", systemImage: MixtapeIcons.play) { run { await Self.play($0, with: $1) } }
            Button("Shuffle", systemImage: MixtapeIcons.shuffle) { run { await Self.play($0.shuffled(), with: $1) } }

            Divider()

            // One batch each, never the single-song calls in a loop: those warm
            // every song's file before queueing it, so a whole album landed
            // minutes after the click.
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                run { await $1.onlineCoordinator.playNext($0) }
            }
            Button("Add to Queue", systemImage: "text.append") {
                run { await $1.onlineCoordinator.addToQueue($0) }
            }
        }

        switch collection {
        case .album(let album):
            Divider()
            albumLibraryItems(album)
            Divider()
            goToArtist(ImportService.creditedArtists(from: album.artistName))
            if showsShare { ShareMenuItems(.album(album)) }
        case .artist(let artist):
            if showsShare {
                Divider()
                ShareMenuItems(.artist(artist))
            }
        case .mix(let mix):
            Divider()
            mixLibraryItems(mix)
            goToArtist(mix.seedArtist.isEmpty ? [] : [mix.seedArtist])
            if let saved = savedMix(mix) {
                Divider()
                PlaylistShareMenuItems(playlist: saved)
            }
        }
    }

    // MARK: - Library

    @ViewBuilder
    private func albumLibraryItems(_ album: OnlineAlbum) -> some View {
        let isSaved = savedAlbums.isSaved(title: album.title, artistName: album.artistName)
        Button(isSaved ? "Remove from Library" : "Add to Library",
               systemImage: isSaved ? "checkmark.circle.fill" : "plus.circle") {
            // The album page's + button, item for item.
            savedAlbums.setSaved(!isSaved, title: album.title, artistName: album.artistName)
            guard !isSaved else { return }
            run { await $1.onlineCoordinator.addAlbumToLibrary($0) }
            deps.showSavedToast(.library)
        }

        // Once its songs are library rows the download state is known, and the
        // bulk items say exactly what's left. Before that nothing is on disk,
        // so plain "Download" is the whole truth — it saves on the way, the way
        // the album page's download button does.
        if isSaved, let owned = deps.libraryService.album(title: album.title, artistName: album.artistName) {
            BulkDownloadMenuItems(tracks: deps.libraryService.tracks(in: owned),
                                  downloads: deps.downloadManager)
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                savedAlbums.setSaved(true, title: album.title, artistName: album.artistName)
                run { songs, deps in
                    await deps.onlineCoordinator.addAlbumToLibrary(songs)
                    for song in songs {
                        if let row = deps.libraryService.track(id: song.stableTrackID) {
                            deps.downloadManager.download(row)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mixLibraryItems(_ mix: PersonalMix) -> some View {
        if let saved = savedMix(mix) {
            BulkDownloadMenuItems(tracks: saved.trackIDs.compactMap { deps.libraryService.track(id: $0) },
                                  downloads: deps.downloadManager)
        } else if !mix.tracks.isEmpty {
            Button("Add to Library", systemImage: "plus.circle") {
                // ponytail: a failed save is silent here — the menu has nowhere
                // to hang the page's alert. Route it through a toast if it bites.
                if deps.importService.saveMix(mix) != nil { deps.showSavedToast(.library) }
            }
        }
    }

    private func savedMix(_ mix: PersonalMix) -> Playlist? {
        guard let p = deps.libraryService.playlist(id: mix.savedPlaylistID), !p.isDeleted else { return nil }
        return p
    }

    // MARK: - Artist

    /// Split the way a track row splits credits: a record by "A & B" offers
    /// both rather than searching for the whole string and finding nobody.
    @ViewBuilder
    private func goToArtist(_ names: [String]) -> some View {
        if names.count > 1 {
            Menu {
                ForEach(names, id: \.self) { name in
                    Button(name) { openArtist(named: name) }
                }
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        } else if let name = names.first, !name.isEmpty {
            Button("Go to Artist", systemImage: "music.mic") { openArtist(named: name) }
        }
    }

    private func openArtist(named name: String) {
        #if os(macOS)
        appState.openDiscoverArtist(named: name)
        #else
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    // MARK: - Songs

    /// A mix with nothing in it has nothing to play; albums and artists can't
    /// know until they're fetched.
    private var isEmptyMix: Bool {
        if case .mix(let mix) = collection { return mix.tracks.isEmpty }
        return false
    }

    /// Load the songs, then act on them. `deps` is handed through because the
    /// menu is gone by the time a fetch comes back.
    private func run(_ work: @escaping @MainActor ([OnlineTrack], AppDependencies) async -> Void) {
        let deps = self.deps
        let collection = self.collection
        Task { @MainActor in
            let songs = await Self.songs(of: collection, using: deps)
            guard !songs.isEmpty else { return }
            await work(songs, deps)
        }
    }

    @MainActor
    private static func songs(of collection: Collection, using deps: AppDependencies) async -> [OnlineTrack] {
        let store = DiscoverSessionStore.shared
        switch collection {
        case .album(let album):
            if let cached = store.cachedAlbumTracks(for: album) { return cached }
            return await store.albumTracks(for: album, using: deps.itunesClient)
        case .artist(let artist):
            if let cached = store.cachedArtistCatalogue(for: artist) { return cached.top }
            return await store.artistCatalogue(for: artist, using: deps.itunesClient).top
        case .mix(let mix):
            return mix.tracks
        }
    }

    private static func play(_ songs: [OnlineTrack], with deps: AppDependencies) async {
        guard let first = songs.first else { return }
        var artwork: Data? = nil
        if let url = first.artworkURL { artwork = try? await URLSession.shared.data(from: url).0 }
        await deps.onlineCoordinator.play(first, context: songs, artworkData: artwork)
    }
}
