// ImportService.swift
// Mixtape — Core/Services
//
// Orchestrates the full import pipeline:
//   1. Receive a security-scoped URL from the file picker
//   2. Parse metadata with MetadataParser
//   3. Copy the audio file into the sandbox via MusicFileManager (SHA-256 dedup)
//   4. Persist Track/Album/Artist via their repositories
//   5. Notify LibraryService to refresh its published state
//
// Artist grouping rules
// ---------------------
// Tracks are filed under the *primary artist* — the first name before any
// "featuring" separator (" & ", " ft. ", " feat. ", " featuring ", " x ").
// "Pitbull ft. Kesha"   → filed under "Pitbull"
// "EsDeeKid & Rico Ace" → filed under "EsDeeKid"
// The full artist string is still stored on the Track for display purposes.
// The user can override the primary artist in the metadata review sheet
// ("Filed Under" field) or post-import via "Move to Artist Folder…".

import Foundation
import SwiftData

// MARK: - Import Result

public enum ImportResult {
    case imported(Track, EnrichmentCandidate) // new track; always has a candidate for review
    case duplicate(Track)                     // same file hash already exists; no-op
    case failed(URL, Error)                   // import failed for this URL
}

// MARK: - Import Service

@MainActor
public final class ImportService {

    // MARK: - Dependencies

    private let fileManager:       MusicFileManager
    private let metadataParser:    MetadataParser
    private let enrichmentService: MetadataEnrichmentService?
    private let trackRepo:         TrackRepository
    private let albumRepo:         AlbumRepository
    private let artistRepo:        ArtistRepository
    private let libraryService:    LibraryService
    private let deviceID:          String

    // MARK: - Post-Import Sync Hook

    /// Set by AppDependencies to trigger an upstream sync after any successful import.
    /// Debounced — a batch of 200 songs collapses into one sync fired 1 s after the
    /// last track lands, so there is exactly one network round-trip per import session.
    var onSyncNeeded: (() async -> Void)?
    private var pendingSyncTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        fileManager:       MusicFileManager,
        metadataParser:    MetadataParser,
        enrichmentService: MetadataEnrichmentService? = nil,
        trackRepo:         TrackRepository,
        albumRepo:         AlbumRepository,
        artistRepo:        ArtistRepository,
        libraryService:    LibraryService,
        deviceID:          String
    ) {
        self.fileManager       = fileManager
        self.metadataParser    = metadataParser
        self.enrichmentService = enrichmentService
        self.trackRepo         = trackRepo
        self.albumRepo         = albumRepo
        self.artistRepo        = artistRepo
        self.libraryService    = libraryService
        self.deviceID          = deviceID
    }

    // MARK: - Primary Artist Parsing

    /// Strips "featuring" suffixes and returns the primary (first) artist name.
    /// Used for album/artist folder grouping — the full artist string is kept
    /// on the Track itself for display.
    ///
    /// Examples:
    ///   "Pitbull ft. Kesha"   → "Pitbull"
    ///   "EsDeeKid & Rico Ace" → "EsDeeKid"
    ///   "Adele"               → "Adele"
    public static func primaryArtistName(from artistName: String) -> String {
        splitArtist(from: artistName).primary
    }

    /// Splits "EsDeeKid & Kesha" into ("EsDeeKid", "Kesha").
    /// Returns (artistName, nil) when no featured separator is found.
    public static func splitArtist(from artistName: String) -> (primary: String, featured: String?) {
        let separators = [" & ", " ft. ", " ft ", " feat. ", " feat ", " featuring ", " x "]
        for sep in separators {
            if let range = artistName.range(of: sep, options: .caseInsensitive) {
                let primary  = String(artistName[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let featured = String(artistName[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !primary.isEmpty {
                    return (primary, featured.isEmpty ? nil : featured)
                }
            }
        }
        return (artistName, nil)
    }

    // MARK: - Single File Import

    /// Import one audio file. Handles security-scoped resource access internally.
    public func importTrack(from url: URL) async -> ImportResult {
        // 1. Security-scoped access
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            // 2. Copy + hash
            let provenance = try fileManager.importFile(from: url)

            // 3. Check for duplicate
            let existingIDs = try trackRepo.existingIDs(forFileHash: provenance.fileHash)
            if let existingID = existingIDs.first,
               let existing = try trackRepo.fetch(id: existingID) {
                return .duplicate(existing)
            }

            // 4. Parse metadata
            let meta = try await metadataParser.parse(url: url)

            // 5. Build domain track
            let track = Track(
                title:       meta.title,
                artistName:  meta.artistName,
                albumTitle:  meta.albumTitle,
                duration:    meta.duration,
                trackNumber: meta.trackNumber,
                discNumber:  meta.discNumber,
                year:        meta.year,
                genre:       meta.genre,
                artworkData: meta.artworkData,
                composer:    meta.composer,
                sync:        SyncMetadata(deviceID: deviceID),
                file:        provenance
            )

            // 6. Persist track
            try trackRepo.save(track)

            // 7. Update or create album (grouped by primary artist)
            try updateAlbum(for: track)

            // 8. Update or create artist (primary artist only)
            try updateArtist(for: track)

            // 9. Refresh in-memory library
            libraryService.refresh()

            // 10. Add to All Songs — every imported track lands there automatically.
            libraryService.addToAllSongs(trackID: track.id)

            // 11. Schedule a debounced sync so the server sees the new tracks
            //     without the caller having to think about it.
            scheduleSync()

            // 12. Run metadata enrichment (async iTunes lookup).
            //     Always returns a candidate so every track goes through the review
            //     sheet. When metadata is already complete, a passthrough candidate
            //     with source=.existingMetadata is used so the user can confirm tags.
            let enriched  = await enrichmentService?.enrich(url: url, existing: meta)
            let candidate = enriched ?? EnrichmentCandidate(
                title:       meta.title,
                artistName:  meta.artistName != "Unknown Artist" ? meta.artistName : nil,
                albumTitle:  meta.albumTitle != "Unknown Album"  ? meta.albumTitle : nil,
                year:        meta.year,
                genre:       meta.genre,
                trackNumber: meta.trackNumber,
                confidence:  1.0,
                source:      .existingMetadata
            )

            return .imported(track, candidate)

        } catch {
            return .failed(url, error)
        }
    }

    // MARK: - Batch Import

    /// Import multiple files; returns one result per URL.
    public func importTracks(from urls: [URL]) async -> [ImportResult] {
        var results: [ImportResult] = []
        for url in urls {
            let result = await importTrack(from: url)
            results.append(result)
        }
        return results
    }

    // MARK: - Apply Enrichment

    /// Writes confirmed metadata + downloaded artwork back to the stored track,
    /// then re-links the track to the correct album and artist folders.
    ///
    /// - Parameter primaryArtistOverride: If supplied, the track is filed under
    ///   this artist instead of the auto-parsed primary artist. Used when the
    ///   user manually specifies the Artist value in the review sheet.
    public func applyEnrichment(
        trackID:               UUID,
        title:                 String,
        artistName:            String,
        albumTitle:            String,
        year:                  Int?,
        genre:                 String?,
        artworkURL:            URL?,
        artistImageURL:        URL? = nil,
        primaryArtistOverride: String? = nil
    ) async {
        // 1. Download album artwork and artist profile photo concurrently (if URLs provided)
        var artworkData:      Data? = nil
        var artistImageData:  Data? = nil
        await withTaskGroup(of: Void.self) { group in
            if let url = artworkURL {
                group.addTask { artworkData = try? await URLSession.shared.data(from: url).0 }
            }
            if let url = artistImageURL {
                group.addTask { artistImageData = try? await URLSession.shared.data(from: url).0 }
            }
        }

        // 2. Fetch current track
        guard var track = try? trackRepo.fetch(id: trackID) else { return }
        
        let oldArtist = track.artistName
        let oldTitle = track.title

        // 3. Update the track with confirmed metadata
        track.title      = title
        track.artistName = artistName
        track.albumTitle = albumTitle
        track.year       = year
        track.genre      = genre
        if let data = artworkData { track.artworkData = data }
        track.sync.markModified()
        try? trackRepo.save(track)

        if ExportManager.shared.syncMetadataToDisk {
            ExportManager.shared.updateMetadataOnDisk(for: track, oldArtist: oldArtist, oldTitle: oldTitle)
        }

        // 4. Re-link to the correct album + artist.
        //    relinkTrack searches by actual track membership, not by guessing
        //    the old bucket from the artist name string.
        let primary = primaryArtistOverride ?? ImportService.primaryArtistName(from: artistName)
        try? relinkTrack(
            id:            trackID,
            toAlbumTitle:  albumTitle,
            primaryArtist: primary,
            artwork:       artworkData ?? track.artworkData,
            artistArtwork: artistImageData,
            year:          year
        )

        // 5. Refresh + sync
        libraryService.refresh()
        scheduleSync()
    }

    // MARK: - Rebuild All Groupings

    /// Re-files every track in the library under its correct primary artist + album.
    ///
    /// Useful as a one-time repair when old import bugs left tracks in the wrong
    /// bucket or with empty album/artist entries. Tracks whose `artistName` already
    /// contains a featuring separator ("ft.", "feat.", "&") are automatically split;
    /// tracks with a simple solo artist name are left where they are unless they have
    /// no album/artist bucket at all.
    public func rebuildGroupings() async {
        guard let tracks = try? trackRepo.fetchAll() else { return }
        for track in tracks {
            let primary = ImportService.primaryArtistName(from: track.artistName)
            try? relinkTrack(
                id:            track.id,
                toAlbumTitle:  track.albumTitle,
                primaryArtist: primary,
                artwork:       track.artworkData,
                year:          track.year
            )
        }
        // Always sweep after the loop — relinkTrack may have returned early
        // (track already in correct place) without running cleanupEmptyBuckets.
        cleanupEmptyBuckets()
        libraryService.refresh()
    }

    // MARK: - Move to Artist Folder (post-import reassignment)

    /// Re-files an already-imported track under a different artist folder
    /// without changing its display artist name.
    ///
    /// Use case: a track stored as "Pitbull ft. Kesha" was auto-grouped under
    /// "Kesha" (bad enrichment) but the user wants it under "Pitbull".
    public func moveToArtistFolder(trackID: UUID, newPrimaryArtist: String) async {
        guard let track = try? trackRepo.fetch(id: trackID) else { return }
        try? relinkTrack(
            id:            trackID,
            toAlbumTitle:  track.albumTitle,
            primaryArtist: newPrimaryArtist,
            artwork:       track.artworkData,
            year:          track.year
        )
        libraryService.refresh()
        scheduleSync()
    }

    // MARK: - Sync Scheduling

    private func scheduleSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task {
            // 1-second debounce window: keep resetting while tracks are still arriving,
            // then fire once everything has landed.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            print("[ImportService] ⬆︎ Auto-sync triggered after import")
            await onSyncNeeded?()
        }
    }

    // MARK: - Private Helpers

    /// Creates or updates the album for `track`, using the primary artist name for grouping.
    private func updateAlbum(for track: Track) throws {
        let primary = ImportService.primaryArtistName(from: track.artistName)
        var album = try albumRepo.findOrCreate(
            title:      track.albumTitle,
            artistName: primary,
            deviceID:   deviceID
        )

        if !album.trackIDs.contains(track.id) {
            album.trackIDs.append(track.id)

            // Propagate artwork + year from the track if the album doesn't have them yet
            if album.artworkData == nil {
                album.artworkData = track.artworkData
            }
            if album.year == nil {
                album.year = track.year
            }

            album.sync.markModified()
            try albumRepo.save(album)
        }
    }

    /// Creates or updates the artist for `track`, using the primary artist name for grouping.
    private func updateArtist(for track: Track) throws {
        let primary = ImportService.primaryArtistName(from: track.artistName)
        var artist = try artistRepo.findOrCreate(
            name:     primary,
            deviceID: deviceID
        )

        var modified = false

        if !artist.trackIDs.contains(track.id) {
            artist.trackIDs.append(track.id)
            modified = true
        }

        // Link album to artist (album was already created/found by updateAlbum)
        if let album = try albumRepo
            .fetchAll()
            .first(where: { $0.title == track.albumTitle && $0.artistName == primary }),
           !artist.albumIDs.contains(album.id) {
            artist.albumIDs.append(album.id)
            modified = true
        }

        // Propagate artwork
        if artist.artworkData == nil, let art = track.artworkData {
            artist.artworkData = art
            modified = true
        }

        if modified {
            artist.sync.markModified()
            try artistRepo.save(artist)
        }
    }

    /// Moves a track to the correct album + artist bucket.
    ///
    /// Searches by actual track membership (not by reconstructing the old bucket
    /// from the artist name string) so it works correctly even after bad previous
    /// enrichments that left the track in the wrong — or no — bucket.
    ///
    /// Algorithm:
    ///   1. Find every album/artist that currently contains this track ID.
    ///   2. Remove from all buckets that are NOT the target.
    ///   3. Add to the target bucket, creating it if needed.
    ///   4. Sweep and soft-delete any remaining empty orphan buckets.
    private func relinkTrack(
        id trackID:    UUID,
        toAlbumTitle:  String,
        primaryArtist: String,
        artwork:       Data?,          // album/track artwork
        artistArtwork: Data? = nil,    // artist profile photo (Deezer) — separate from album art
        year:          Int?
    ) throws {
        let allAlbums  = (try? albumRepo.fetchAll())  ?? []
        let allArtists = (try? artistRepo.fetchAll()) ?? []

        // Albums/artists that currently hold this track
        let holdingAlbums  = allAlbums .filter { $0.trackIDs.contains(trackID) }
        let holdingArtists = allArtists.filter { $0.trackIDs.contains(trackID) }

        // Split into "already in target" vs. "wrong bucket"
        let inTargetAlbum  = holdingAlbums .contains { $0.title == toAlbumTitle && $0.artistName == primaryArtist }
        let inTargetArtist = holdingArtists.contains { $0.name == primaryArtist }
        let wrongAlbums    = holdingAlbums .filter   { !($0.title == toAlbumTitle && $0.artistName == primaryArtist) }
        let wrongArtists   = holdingArtists.filter   { $0.name != primaryArtist }

        // ── Nothing to do? ────────────────────────────────────────────────────
        if inTargetAlbum && inTargetArtist && wrongAlbums.isEmpty && wrongArtists.isEmpty {
            // Already correct — propagate artwork (always overwrite so iTunes/Deezer beats local embedded art)
            if let art = artwork, var a = holdingAlbums.first {
                a.artworkData = art; a.sync.markModified(); try? albumRepo.save(a)
            }
            if let artistArt = artistArtwork {
                // Specific artist photo exists (Deezer) — overwrite
                if var a = holdingArtists.first {
                    a.artworkData = artistArt; a.sync.markModified(); try? artistRepo.save(a)
                }
            } else if let albumArt = artwork, var a = holdingArtists.first, a.artworkData == nil {
                // Fallback album art — only propagate if artist has no art yet
                a.artworkData = albumArt; a.sync.markModified(); try? artistRepo.save(a)
            }
            return
        }

        // ── Remove from wrong album buckets ───────────────────────────────────
        for var album in wrongAlbums {
            album.trackIDs.removeAll { $0 == trackID }
            if album.trackIDs.isEmpty {
                try? albumRepo.softDelete(id: album.id)
            } else {
                album.sync.markModified()
                try? albumRepo.save(album)
            }
        }

        // ── Add to target album ───────────────────────────────────────────────
        if !inTargetAlbum {
            var target = try albumRepo.findOrCreate(
                title: toAlbumTitle, artistName: primaryArtist, deviceID: deviceID
            )
            if !target.trackIDs.contains(trackID) {
                target.trackIDs.append(trackID)
                if target.artworkData == nil, let art = artwork { target.artworkData = art }
                if target.year == nil { target.year = year }
                target.sync.markModified()
                try albumRepo.save(target)
            }
        }

        // ── Resolve target album ID for artist linking ────────────────────────
        let targetAlbumID = (try? albumRepo.fetchAll())?.first(where: {
            $0.title == toAlbumTitle && $0.artistName == primaryArtist
        })?.id

        // ── Remove from wrong artist buckets ──────────────────────────────────
        // Track which album IDs were emptied so we can unlink them from artists.
        let emptiedAlbumIDs = Set(
            wrongAlbums.filter { $0.trackIDs.filter({ $0 != trackID }).isEmpty }.map(\.id)
        )
        for var artist in wrongArtists {
            artist.trackIDs.removeAll { $0 == trackID }
            artist.albumIDs.removeAll  { emptiedAlbumIDs.contains($0) }
            if artist.trackIDs.isEmpty {
                try? artistRepo.softDelete(id: artist.id)
            } else {
                artist.sync.markModified()
                try? artistRepo.save(artist)
            }
        }

        // ── Add to target artist ──────────────────────────────────────────────
        var targetArtist = try artistRepo.findOrCreate(name: primaryArtist, deviceID: deviceID)
        var artistModified = false
        if !targetArtist.trackIDs.contains(trackID) {
            targetArtist.trackIDs.append(trackID)
            artistModified = true
        }
        if let aID = targetAlbumID, !targetArtist.albumIDs.contains(aID) {
            targetArtist.albumIDs.append(aID)
            artistModified = true
        }
        // Prefer Deezer profile photo; fall back to album art ONLY if the artist has no profile image yet
        if let artistArt = artistArtwork {
            targetArtist.artworkData = artistArt
            artistModified = true
        } else if targetArtist.artworkData == nil, let albumArt = artwork {
            targetArtist.artworkData = albumArt
            artistModified = true
        }
        if artistModified {
            targetArtist.sync.markModified()
            try artistRepo.save(targetArtist)
        }

        // ── Sweep orphaned empty buckets from previous bad states ─────────────
        cleanupEmptyBuckets()
    }

    /// Soft-deletes any album or artist entity with no tracks remaining.
    /// Called after every relink to remove orphan buckets left by prior bad enrichments.
    private func cleanupEmptyBuckets() {
        if let albums = try? albumRepo.fetchAll() {
            for album in albums where album.trackIDs.isEmpty {
                try? albumRepo.softDelete(id: album.id)
            }
        }
        if let artists = try? artistRepo.fetchAll() {
            for artist in artists where artist.trackIDs.isEmpty {
                try? artistRepo.softDelete(id: artist.id)
            }
        }
    }
}
