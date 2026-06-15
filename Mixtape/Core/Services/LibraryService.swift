// LibraryService.swift
// Mixtape — Core/Services
//
// Single source of truth for the in-memory library.
// Reads from the SwiftData repositories and vends @Published collections
// that ViewModels can observe.

import Foundation
import SwiftData
import Combine

@MainActor
public final class LibraryService: ObservableObject {

    // MARK: - Published Library State

    @Published public private(set) var tracks:    [Track]    = []
    @Published public private(set) var albums:    [Album]    = []
    @Published public private(set) var artists:   [Artist]   = []
    /// Playlists, with Favourites always pinned at index 0.
    @Published public private(set) var playlists: [Playlist] = []

    // MARK: - Dependencies

    private let trackRepo:    TrackRepository
    private let albumRepo:    AlbumRepository
    private let artistRepo:   ArtistRepository
    private let playlistRepo: PlaylistRepository
    private let favoriteRepo: FavoriteRepository
    private let deviceID:     String

    // MARK: - Init

    public init(
        trackRepo:    TrackRepository,
        albumRepo:    AlbumRepository,
        artistRepo:   ArtistRepository,
        playlistRepo: PlaylistRepository,
        favoriteRepo: FavoriteRepository,
        deviceID:     String
    ) {
        self.trackRepo    = trackRepo
        self.albumRepo    = albumRepo
        self.artistRepo   = artistRepo
        self.playlistRepo = playlistRepo
        self.favoriteRepo = favoriteRepo
        self.deviceID     = deviceID

        // Ensure both system playlists exist on every launch.
        try? playlistRepo.ensureFavourites(deviceID: deviceID)
        let allSongsIsNew = (try? playlistRepo.ensureAllSongs(deviceID: deviceID)) ?? false

        // Migration: if All Songs was just created and there are already tracks in
        // the library (user upgrading from an older build), seed it in a single save
        // so the playlist isn't empty for existing users.
        if allSongsIsNew,
           let existingTracks = try? trackRepo.fetchAll(),
           !existingTracks.isEmpty,
           var allSongs = try? playlistRepo.fetch(id: Playlist.allSongsID) {
            allSongs.trackIDs = existingTracks.map(\.id)
            allSongs.touch()
            try? playlistRepo.save(allSongs)
        }
    }

    // MARK: - Refresh

    /// Re-reads all entities from SwiftData and updates published properties.
    /// Cross-references album/artist trackID arrays against live tracks so that
    /// any bucket whose songs have all been deleted is soft-deleted and hidden.
    public func refresh() {
        do {
            let allTracks  = try trackRepo.fetchAll()
            let allAlbums  = try albumRepo.fetchAll()
            let allArtists = try artistRepo.fetchAll()

            let liveIDs = Set(allTracks.map(\.id))

            // Sweep albums: soft-delete any whose trackIDs contain no live tracks
            for var album in allAlbums {
                let live = album.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else if live.count != album.trackIDs.count {
                    // Prune stale IDs while we're here
                    album.trackIDs = live
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }

            // Sweep artists: same
            for var artist in allArtists {
                let live = artist.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else if live.count != artist.trackIDs.count {
                    artist.trackIDs = live
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }

            tracks  = allTracks
            albums  = allAlbums .filter { !$0.trackIDs.filter({ liveIDs.contains($0) }).isEmpty }
            artists = allArtists.filter { !$0.trackIDs.filter({ liveIDs.contains($0) }).isEmpty }

            // Ensure All Songs is always a perfectly accurate reflection of the local library.
            // Since tracks can be synced from other devices, we dynamically rebuild the All Songs
            // playlist on every refresh to guarantee it matches exactly what we have locally.
            if var allSongs = try? playlistRepo.fetch(id: Playlist.allSongsID) {
                let expectedIDs = allTracks.sorted { $0.dateImported < $1.dateImported }.map(\.id)
                if allSongs.trackIDs != expectedIDs {
                    allSongs.trackIDs = expectedIDs
                    try? playlistRepo.save(allSongs)
                }
            }
        } catch {
            print("[LibraryService] refresh tracks/albums/artists failed: \(error)")
        }
        refreshPlaylists()
    }

    public func refreshPlaylists() {
        do {
            let all = try playlistRepo.fetchAll()
            let meta = PlaylistMetadataService.shared
            
            // Pinned Playlists
            var pinned = all.filter { meta.isPinned(playlistID: $0.id) }
            // Sort pinned alphabetically, but keep All Songs first and Favourites second
            pinned.sort { a, b in
                if a.isAllSongs { return true }
                if b.isAllSongs { return false }
                if a.isFavourites { return true }
                if b.isFavourites { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            
            // Unpinned Playlists
            var unpinned = all.filter { !meta.isPinned(playlistID: $0.id) }
            // Sort dynamically by last played date (newest first)
            unpinned.sort { a, b in
                let dateA = meta.playlistLastPlayedDates[a.id] ?? Date.distantPast
                let dateB = meta.playlistLastPlayedDates[b.id] ?? Date.distantPast
                if dateA != dateB {
                    return dateA > dateB
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            
            playlists = pinned + unpinned
        } catch {
            print("[LibraryService] refresh playlists failed: \(error)")
        }
    }

    // MARK: - Clear

    public func clearAll() {
        do {
            try trackRepo.deleteAll()
            try albumRepo.deleteAll()
            try artistRepo.deleteAll()
        } catch {
            print("[LibraryService] clearAll failed: \(error)")
        }
        let musicDir = URL.documentsDirectory.appending(path: "Music")
        if FileManager.default.fileExists(atPath: musicDir.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: musicDir)
        }
        // Reset system playlists to empty (keep the playlists, wipe their track lists)
        for systemID in [Playlist.favouritesID, Playlist.allSongsID] {
            if var p = try? playlistRepo.fetch(id: systemID) {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }
        refresh()
    }

    // MARK: - Bulk Delete (Settings actions)

    /// Deletes every track, album, and artist from the local store.
    /// All playlist trackID arrays are emptied; the playlists themselves remain.
    /// Call `syncService.deleteAllServerTracks()` BEFORE this to push the deletion.
    public func deleteAllTracks() {
        do { try trackRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — trackRepo.deleteAll failed: \(error)")
        }
        do { try albumRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — albumRepo.deleteAll failed: \(error)")
        }
        do { try artistRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — artistRepo.deleteAll failed: \(error)")
        }
        try? favoriteRepo.deleteAll()

        // Remove local audio files.
        let musicDir = URL.documentsDirectory.appending(path: "Music")
        if FileManager.default.fileExists(atPath: musicDir.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: musicDir)
        }

        // Empty every playlist's track list (keeps the playlist structures intact).
        if let all = try? playlistRepo.fetchAll() {
            for var p in all where !p.trackIDs.isEmpty {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }

        refresh()
    }

    /// Soft-deletes all user-created playlists locally. System playlists
    /// (All Songs, Favourites) are kept. Tracks are untouched.
    /// Call `syncService.deleteAllServerUserPlaylists()` BEFORE this to push the deletion.
    public func deleteAllUserPlaylists() {
        guard let all = try? playlistRepo.fetchAll() else { return }
        for playlist in all where !playlist.isSystem {
            try? playlistRepo.softDelete(id: playlist.id)
        }
        refreshPlaylists()
    }

    // MARK: - Favourites

    public func isFavourited(trackID: UUID) -> Bool {
        (try? favoriteRepo.isFavourited(trackID: trackID)) ?? false
    }

    @discardableResult
    public func toggleFavourite(trackID: UUID) -> Bool {
        // Guard: don't allow favouriting a track that has been deleted from the library.
        // This prevents a stale mini-player from creating a phantom Favourites entry.
        guard track(id: trackID) != nil else { return false }
        if isFavourited(trackID: trackID) {
            try? favoriteRepo.remove(trackID: trackID)
            mutatePlaylist(id: Playlist.favouritesID) { $0.removeTrack(trackID) }
            refreshPlaylists()   // publish change so heart icon & Favourites list update immediately
            return false
        } else {
            try? favoriteRepo.add(trackID: trackID, deviceID: deviceID)
            mutatePlaylist(id: Playlist.favouritesID) { $0.addTrack(trackID) }
            refreshPlaylists()   // publish change so heart icon & Favourites list update immediately
            return true
        }
    }

    /// Called by ImportService after every successful import to add the track to All Songs.
    public func addToAllSongs(trackID: UUID) {
        mutatePlaylist(id: Playlist.allSongsID) { $0.addTrack(trackID) }
        refreshPlaylists()
    }

    // MARK: - Playlist Management

    public func createPlaylist(
        name: String,
        description: String? = nil,
        artworkData: Data? = nil
    ) -> Playlist {
        let p = Playlist(
            name:        name,
            description: description,
            artworkData: artworkData,
            sync:        SyncMetadata(deviceID: deviceID)
        )
        try? playlistRepo.save(p)
        refreshPlaylists()
        return p
    }

    public func deletePlaylist(id: UUID) {
        guard id != Playlist.favouritesID, id != Playlist.allSongsID else { return }
        try? playlistRepo.softDelete(id: id)
        refreshPlaylists()
    }

    public func renamePlaylist(id: UUID, newName: String) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        mutatePlaylist(id: id) { $0.name = newName; $0.touch() }
        refreshPlaylists()
    }

    public func updatePlaylist(id: UUID, name: String, description: String?, artworkData: Data?) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        mutatePlaylist(id: id) { 
            $0.name = name
            $0.description = description
            $0.artworkData = artworkData
            $0.touch()
        }
        refreshPlaylists()
    }

    // MARK: - Track ↔ Playlist

    public func addTrack(id trackID: UUID, toPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) { $0.addTrack(trackID) }
        // Keep FavoriteEntity in sync when adding to Favourites from a context menu
        if playlistID == Playlist.favouritesID {
            try? favoriteRepo.add(trackID: trackID, deviceID: deviceID)
        }
        refreshPlaylists()
    }

    /// Removes a track from ONE specific playlist. Does NOT delete it from the library.
    public func removeTrack(id trackID: UUID, fromPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) { $0.removeTrack(trackID) }
        if playlistID == Playlist.favouritesID {
            try? favoriteRepo.remove(trackID: trackID)
        }
        refreshPlaylists()
    }

    // MARK: - Shared / Collaborative Playlists

    /// Imports a metadata-only placeholder Track from a shared-playlist snapshot, so a
    /// song that this device doesn't have the audio file for still appears (and is
    /// labelled unavailable). The placeholder carries no local file: `file.localPath`
    /// is empty and `uploaded` is false — the same convention used elsewhere to mean
    /// "no local audio". If a real track with this id already exists locally, it's
    /// kept as-is and returned unchanged.
    ///
    /// Returns the track id (always equal to `meta.id`).
    @discardableResult
    public func importPlaceholderTrack(meta: PlaylistSharingService.SharedTrackMeta) -> UUID {
        if let existing = ((try? trackRepo.fetch(id: meta.id)) ?? nil), !existing.isDeleted {
            return existing.id
        }
        let placeholder = Track(
            id: meta.id,
            title: meta.title,
            artistName: meta.artist,
            albumTitle: meta.album,
            duration: meta.duration,
            sync: SyncMetadata(deviceID: deviceID),
            file: FileProvenance(fileHash: "", fileSize: 0, localPath: "")
        )
        try? trackRepo.save(placeholder)
        return placeholder.id
    }

    /// Reconciles a local (shared) playlist's track list to match a remote snapshot.
    /// For every remote track id: if it exists locally it's linked directly; otherwise
    /// a placeholder is imported from the snapshot metadata so the song is visible.
    /// The local playlist's `trackIDs` are then set to exactly the remote order.
    public func reconcileSharedPlaylist(
        localPlaylistID: UUID,
        remoteTrackIDs: [UUID],
        remoteTrackMeta: [PlaylistSharingService.SharedTrackMeta]
    ) {
        let metaByID = Dictionary(remoteTrackMeta.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Ensure a local Track row exists for every remote id (real or placeholder).
        for trackID in remoteTrackIDs {
            let existsInRepo = ((try? trackRepo.fetch(id: trackID)) ?? nil) != nil
            if track(id: trackID) == nil, !existsInRepo, let meta = metaByID[trackID] {
                importPlaceholderTrack(meta: meta)
            }
        }

        // Set the playlist's order to exactly match the remote list.
        mutatePlaylist(id: localPlaylistID) { playlist in
            if playlist.trackIDs != remoteTrackIDs {
                playlist.trackIDs = remoteTrackIDs
                playlist.touch()
            }
        }

        refresh()
    }

    // MARK: - Delete Single Track From Library

    /// Soft-deletes a track from the library, removes its audio file,
    /// strips it from every playlist, and removes it from its album/artist
    /// buckets — soft-deleting those too if they become empty.
    public func deleteTrack(id: UUID) {
        let existing = track(id: id)
        do {
            try trackRepo.softDelete(id: id)
        } catch {
            print("[LibraryService] deleteTrack(\(id)) failed: \(error)")
            return
        }
        // Remove local audio file
        if let localPath = existing?.file.localPath {
            let url: URL = localPath.hasPrefix("/")
                ? URL(fileURLWithPath: localPath)
                : URL.documentsDirectory.appending(path: localPath)
            try? FileManager.default.removeItem(at: url)
        }
        // Purge from every playlist (including Favourites)
        if var all = try? playlistRepo.fetchAll() {
            for i in all.indices where all[i].trackIDs.contains(id) {
                all[i].removeTrack(id)
                try? playlistRepo.save(all[i])
            }
        }
        // Remove from FavoriteEntity
        try? favoriteRepo.remove(trackID: id)

        // Remove from album buckets — soft-delete the album if it becomes empty
        if let allAlbums = try? albumRepo.fetchAll() {
            for var album in allAlbums where album.trackIDs.contains(id) {
                album.trackIDs.removeAll { $0 == id }
                if album.trackIDs.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else {
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }
        }

        // Remove from artist buckets — soft-delete the artist if it becomes empty
        if let allArtists = try? artistRepo.fetchAll() {
            for var artist in allArtists where artist.trackIDs.contains(id) {
                artist.trackIDs.removeAll { $0 == id }
                if artist.trackIDs.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else {
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }
        }

        refresh()
    }

    // MARK: - Convenience Accessors

    public func track(id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    public func album(id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    public func artist(id: UUID) -> Artist? {
        artists.first { $0.id == id }
    }

    public func tracks(in album: Album) -> [Track] {
        let ids = Set(album.trackIDs)
        return tracks
            .filter { ids.contains($0.id) }
            .sorted {
                let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
                if d0 != d1 { return d0 < d1 }
                return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
            }
    }

    public func tracks(by artist: Artist) -> [Track] {
        let ids = Set(artist.trackIDs)
        return tracks.filter { ids.contains($0.id) }
    }

    /// Re-fetches the artist's profile picture from Deezer and updates the database.
    public func refreshArtistImage(artistID: UUID) async throws {
        guard let artist = artist(id: artistID) else { return }
        let client = ITunesSearchClient()
        let primary = ImportService.primaryArtistName(from: artist.name)
        guard let url = await client.artistImageURL(for: primary) else {
            throw NSError(
                domain: "LibraryService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No image found for '\(primary)' on Deezer."]
            )
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(
                domain: "LibraryService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to download image."]
            )
        }
        
        var mutableArtist = artist
        mutableArtist.artworkData = data
        mutableArtist.sync.markModified()
        try artistRepo.save(mutableArtist)
        
        refresh()
    }

    public func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Private Helpers

    private func mutatePlaylist(id: UUID, body: (inout Playlist) -> Void) {
        guard var p = try? playlistRepo.fetch(id: id) else { return }
        body(&p)
        try? playlistRepo.save(p)
    }
}

// touch() is defined on Playlist directly (see Core/Models/Playlist.swift)
