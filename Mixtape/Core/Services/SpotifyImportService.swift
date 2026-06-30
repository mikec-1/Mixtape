// SpotifyImportService.swift
// Mixtape
//
// Rebuilds a Spotify playlist locally — same name, cover and songs. Tracks come in
// as online Tracks (no file), so they import instantly and resolve audio on first
// play like any Discover track. Fetching happens in SpotifyClient; this is just the
// "turn a SpotifyPlaylist into library rows" half.

import Foundation

@MainActor
public final class SpotifyImportService {

    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
    }

    private let trackRepo: TrackRepository
    private let libraryService: LibraryService
    private let deviceID: String
    private let session: URLSession

    public init(
        trackRepo: TrackRepository,
        libraryService: LibraryService,
        deviceID: String,
        session: URLSession = .shared
    ) {
        self.trackRepo      = trackRepo
        self.libraryService = libraryService
        self.deviceID       = deviceID
        self.session        = session
    }

    @discardableResult
    public func importPlaylist(
        _ playlist: SpotifyPlaylist,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Playlist {
        var coverData: Data? = nil
        if let coverURL = playlist.coverURL {
            coverData = try? await session.data(from: coverURL).0
        }

        // Create it first so it shows up immediately, even if some songs fail.
        let created = libraryService.createPlaylist(
            name:        playlist.name,
            description: playlist.description,
            artworkData: coverData
        )

        let artwork = await fetchArtwork(for: playlist.tracks)

        let total = playlist.tracks.count
        var completed = 0

        for (index, item) in playlist.tracks.enumerated() {
            let online = OnlineTrack(
                title:      item.title,
                artistName: item.artistName,
                albumTitle: item.albumTitle,
                duration:   item.duration,
                artworkURL: item.artworkURL,
                isExplicit: item.isExplicit
            )
            let track = online.asTrack(artworkData: artwork[index], deviceID: deviceID)

            try? trackRepo.save(track) // stableTrackID dedupes re-imports
            libraryService.addToAllSongs(trackID: track.id)
            libraryService.addTrack(id: track.id, toPlaylist: created.id)

            completed += 1
            onProgress?(Progress(completed: completed, total: total))
        }

        libraryService.refresh()
        return created
    }

    /// Album thumbnails fetched in parallel, aligned to `tracks` (nil where missing).
    private func fetchArtwork(for tracks: [SpotifyPlaylistTrack]) async -> [Data?] {
        var result = [Data?](repeating: nil, count: tracks.count)
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, track) in tracks.enumerated() {
                guard let url = track.artworkURL else { continue }
                group.addTask { [session] in
                    (index, try? await session.data(from: url).0)
                }
            }
            for await (index, data) in group where data != nil {
                result[index] = data
            }
        }
        return result
    }
}
