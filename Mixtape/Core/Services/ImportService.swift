// Import pipeline: security-scoped URL from the picker -> MetadataParser -> copy into the sandbox via
// MusicFileManager (SHA-256 dedup) -> persist Track/Album/Artist -> refresh LibraryService.
// Tracks are filed under the primary artist: the name before an explicit feature marker
// (" ft. ", " feat. ", " featuring "). " & " and " x " don't split, since real bands use them.
// "Pitbull ft. Kesha" -> "Pitbull"; "Simon & Garfunkel" -> "Simon & Garfunkel"
// The full credit is still stored for display. The user can override the filing in the review sheet
// ("Filed Under") or later via "Move to Artist Folder...".

import Foundation
import OSLog
import SwiftData

// MARK: - Import Result

public enum ImportResult {
    case imported(Track, MetadataReviewItem)  // new track; always reviewable
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
    let libraryService:    LibraryService
    private let deviceID:          String

    /// Artist photos from Spotify (never album art) for online imports; one token reused across imports.
    private let onlineArtistImageClient = ITunesSearchClient(spotifyClient: SpotifyClient())

    // MARK: - Post-Import Sync Hook

    /// Set by AppDependencies. Debounced so a batch syncs once, 1s after the last track lands.
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

    /// The primary artist name, feature credits stripped; used for filing. The full credit stays on the Track.
    public nonisolated static func primaryArtistName(from artistName: String) -> String {
        splitArtist(from: artistName).primary
    }

    /// Splits "Pitbull ft. Kesha" into ("Pitbull", "Kesha"); (artistName, nil) with no feature marker.
    /// Never splits on " & " or " x ": filing syncs everywhere, and breaking a band name is worse than filing
    /// a one-off collab under the duo. Same policy as `splitArtists`.
    public nonisolated static func splitArtist(from artistName: String) -> (primary: String, featured: String?) {
        let separators = [" ft. ", " ft ", " feat. ", " feat ", " featuring "]
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

    /// Group names containing a comma or ampersand, matched against the whole credit before any splitting.
    /// Not exhaustive; covers the ones that actually collide.
    nonisolated private static let indivisibleActs: Set<String> = [
        "earth, wind & fire",
        "tyler, the creator",
        "crosby, stills & nash",
        "crosby, stills, nash & young",
        "emerson, lake & palmer",
        "blood, sweat & tears",
        "peter, paul and mary",
        "florence + the machine",
        "sam & dave",
        "kool & the gang"
    ]

    /// Every credited artist as separate names; decides which artist buckets a track is filed under.
    /// - Feature markers ("feat.", "ft.", "featuring") and " x " always split.
    /// - Commas split, and with a comma present " & " / " and " split too ("A, B & C").
    /// - A lone " & " doesn't: "Simon & Garfunkel" is more common than a one-off "A & B".
    /// `indivisibleActs` overrides all of it.
    /// "Yungpalo, c4rl, YT" -> ["Yungpalo", "c4rl", "YT"]; "Earth, Wind & Fire" -> ["Earth, Wind & Fire"]
    public nonisolated static func creditedArtists(from artistName: String) -> [String] {
        let trimmed = artistName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if indivisibleActs.contains(trimmed.lowercased()) { return [trimmed] }

        var separators = [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " x ", " X "]
        if trimmed.contains(",") {
            separators.append(contentsOf: [",", " & ", " and "])
        }

        var parts = [trimmed]
        for sep in separators {
            parts = parts.flatMap { part -> [String] in
                // A known band name that survived this far (e.g. as the featured half) stays whole.
                if indivisibleActs.contains(part.trimmingCharacters(in: .whitespaces).lowercased()) {
                    return [part]
                }
                return part.components(separatedBy: sep)
            }
        }

        // De-duplicate case-insensitively, keeping first-seen order and casing.
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result.isEmpty ? [trimmed] : result
    }

    // MARK: - Printed credit

    /// Every artist to print for a track: the stored credit plus features named in the title (Deezer credits
    /// only the main artist). Display only: the stored credit is part of an online track's identity
    /// (`OnlineTrack.id` is "title|artist"), so it's never widened. Merged case-insensitively.
    public nonisolated static func displayArtists(title: String, artistName: String) -> [String] {
        var names = creditedArtists(from: artistName)
        var seen  = Set(names.map { $0.lowercased() })
        for name in featuredArtists(inTitle: title) {
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Names as a printed credit: "A", "A & B", "A, B & C".
    public static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        default: return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
        }
    }

    /// The title with a bracketed feature credit removed; the inverse of `OnlineTrack.displayTitle`.
    /// "Ran To Atlanta (feat. Future & Molly Santana)" -> "Ran To Atlanta"
    /// Identity is hashed from the bare title, so any key rebuilt from `track.title` needs this spelling.
    /// An unbracketed credit is left alone: `displayTitle` never adds one, so it came from the source.
    public nonisolated static func bareTitle(_ title: String) -> String {
        var text = title
        for (open, close) in [("(", ")"), ("[", "]")] {
            var search = text.startIndex
            while let start = text.range(of: open, range: search..<text.endIndex),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                let inner = text[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if ["feat.", "feat ", "ft.", "ft ", "featuring ", "with "].contains(where: inner.hasPrefix) {
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                    search = start.lowerBound
                } else {
                    search = end.upperBound
                }
            }
        }
        let cleaned = text.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // A title that was only a credit: keep the original rather than return an empty string.
        return cleaned.isEmpty ? title : cleaned
    }

    /// The names in a title's feature credit.
    /// "FRANCHISE (feat. Future, Young Thug & M.I.A.) - REMIX" -> ["Future", "Young Thug", "M.I.A."]
    public nonisolated static func featuredArtists(inTitle title: String) -> [String] {
        guard let marker = featureMarker(in: title) else { return [] }
        var segment = String(title[marker...])
        // A bracketed credit ends with the bracket.
        if let close = segment.firstIndex(where: { $0 == ")" || $0 == "]" }) {
            segment = String(segment[..<close])
        }
        // An unbracketed one ends at a dash or an opening bracket, or "feat. Playboi Carti - Bonus Track"
        // reads as one name.
        if let stop = segment.range(of: " - ") ?? segment.range(of: " \u{2013} ")
            ?? segment.range(of: "(") ?? segment.range(of: "[") {
            segment = String(segment[..<stop.lowerBound])
        }
        return splitFeatureCredit(segment)
    }

    /// Where the featured names start, or nil. Markers only count at a word start ("Drift", "Aftermath").
    nonisolated private static func featureMarker(in title: String) -> String.Index? {
        // "with" only counts inside brackets ("(with Ariana Grande)"); bare "with" is usually the title.
        let markers = ["feat.", "feat ", "ft.", "ft ", "featuring ", "(with ", "[with "]
        var best: String.Index?
        for marker in markers {
            var search = title.startIndex..<title.endIndex
            while let found = title.range(of: marker, options: .caseInsensitive, range: search) {
                let before = found.lowerBound == title.startIndex
                    ? nil
                    : title[title.index(before: found.lowerBound)]
                let opensWord = before.map { !$0.isLetter && !$0.isNumber } ?? true
                if opensWord {
                    if best.map({ found.upperBound < $0 }) ?? true { best = found.upperBound }
                    break
                }
                guard found.upperBound < title.endIndex else { break }
                search = found.upperBound..<title.endIndex
            }
        }
        return best
    }

    /// Splits inside a feature credit. Unlike `creditedArtists`, "&" and "and" always split here.
    nonisolated private static func splitFeatureCredit(_ segment: String) -> [String] {
        var parts = [segment]
        for sep in [",", " & ", " and ", " x ", " + ", "/"] {
            parts = parts.flatMap { part -> [String] in
                if indivisibleActs.contains(part.trimmingCharacters(in: .whitespaces).lowercased()) {
                    return [part]
                }
                return part.components(separatedBy: sep)
            }
        }
        var seen   = Set<String>()
        var result: [String] = []
        for part in parts {
            // Whitespace and dashes only; a punctuation trim would turn "M.I.A." into "M.I.A".
            let name = part.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}"))
            // A name needs a letter or digit; leftover punctuation isn't an artist.
            guard !name.isEmpty, name.count <= 60,
                  name.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    /// Splits a credit into ordered names on feature markers only, recursively, for per-artist tappable
    /// display. Never on "&", " x " or commas ("Earth, Wind & Fire", "Tyler, the Creator").
    public static func splitArtists(from artistName: String) -> [String] {
        let separators = [" featuring ", " feat. ", " feat ", " ft. ", " ft "]
        for sep in separators {
            if let range = artistName.range(of: sep, options: .caseInsensitive) {
                let head = String(artistName[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let tail = String(artistName[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                var result: [String] = []
                if !head.isEmpty { result.append(head) }
                // Recurse so "A feat. B ft. C" yields ["A", "B", "C"].
                result.append(contentsOf: splitArtists(from: tail))
                if !result.isEmpty { return result }
            }
        }
        let trimmed = artistName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    // MARK: - Song Edits

    /// Files a rendered edit as a new song and likes it. Every save is its own copy; the original is
    /// never touched. Kept out of album and artist buckets, see `adoptOrphanTracks`.
    public func saveEdit(rendered url: URL, of original: Track, edit: SongEdit, title: String) async throws -> Track {
        var track = editTrack(of: original, edit: edit, title: title)
        // Tagged before the copy, so the stored file's hash covers the tags.
        try await MP4MetadataWriter.write(track, to: url)
        track.file = try fileManager.importFile(from: url)
        track.file.origin = .edit
        return try fileEdit(track)
    }

    /// Files an edit by its recipe alone (a saved community post); it renders when first played.
    public func saveEdit(recipe edit: SongEdit, of original: Track, title: String) throws -> Track {
        var track = editTrack(of: original, edit: edit, title: title)
        track.file = .editPlaceholder
        // Unique like the web's recipe rows, so it never matches another empty hash.
        track.file.fileHash = "edit:\(track.id.uuidString.lowercased())"
        return try fileEdit(track)
    }

    private func editTrack(of original: Track, edit: SongEdit, title: String) -> Track {
        // The stored row has the cover; rows from a list are loaded without it.
        let original = (try? trackRepo.fetch(id: original.id)) ?? original
        return Track(
            title:       title,
            artistName:  original.artistName,
            albumTitle:  original.albumTitle,
            duration:    (edit.arrangedLength ?? original.duration) / edit.speed,
            year:        original.year,
            genre:       original.genre,
            artworkData: original.artworkData,
            artworkKey:  original.artworkKey,
            composer:    original.composer,
            isExplicit:  original.isExplicit,
            sync:        SyncMetadata(deviceID: deviceID),
            file:        FileProvenance(fileHash: "", fileSize: 0, localPath: ""),
            edit:        edit
        )
    }

    private func fileEdit(_ track: Track) throws -> Track {
        try trackRepo.save(track)
        libraryService.saveToLibrary(trackID: track.id)
        libraryService.scheduleRefresh()
        return track
    }

    /// Swaps an edit's audio for a new render (Re-save Edits, or a rebuild on another device), keeping the
    /// song itself. Returns the updated song.
    @discardableResult
    public func replaceEditAudio(of track: Track, with url: URL) async throws -> Track {
        var track = (try? trackRepo.fetch(id: track.id)) ?? track
        let oldPath = track.file.localPath
        let oldKey = track.file.remoteKey
        try await MP4MetadataWriter.write(track, to: url)
        track.file = try fileManager.importFile(from: url)
        track.file.origin = .edit
        // Others keep streaming the old upload until the new one replaces it (and removes it).
        track.file.remoteKey = oldKey
        try trackRepo.save(track)
        if oldPath != track.file.localPath { AudioPaths.removeAllCopies(ofLocalPath: oldPath) }
        libraryService.scheduleRefresh()
        return track
    }

    // MARK: - Single File Import

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
                // Embedded covers can be several MB and the library keeps them all in memory; shrink on the way in.
                artworkData: ImageDownsampler.artworkJPEG(from: meta.artworkData),
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

            // 9. Refresh the library, coalesced; `importTracks` flushes it when the batch ends.
            libraryService.scheduleRefresh()

            // 11. Debounced sync. Artist rows created here use the album cover until the photo backfill runs.
            scheduleSync()
            libraryService.scheduleArtistImageBackfill()

            // 12. Return something reviewable immediately; the review sheet does the iTunes lookup itself.
            let candidate = enrichmentService?.localCandidate(url: url, existing: meta)
                ?? EnrichmentCandidate(
                    title:       meta.title,
                    artistName:  meta.artistName != "Unknown Artist" ? meta.artistName : nil,
                    albumTitle:  meta.albumTitle != "Unknown Album"  ? meta.albumTitle : nil,
                    year:        meta.year,
                    genre:       meta.genre,
                    trackNumber: meta.trackNumber,
                    confidence:  1.0,
                    source:      .existingMetadata
                )

            let lookup = (enrichmentService?.canImprove(meta) ?? false)
                ? MetadataReviewItem.Lookup(sourceURL: url, existing: meta)
                : nil

            return .imported(track, MetadataReviewItem(track: track,
                                                       candidate: candidate,
                                                       lookup: lookup))

        } catch {
            return .failed(url, error)
        }
    }

    // MARK: - Online Import

    /// Imports an already-downloaded file with caller-supplied metadata (Discover "Add to Library").
    /// The yt-dlp file has no useful tags, so the search result's metadata is trusted and no review runs.
    /// Pass `id` so the row matches the `OnlineTrack`'s `stableTrackID`, or library checks never match it.
    public func importOnlineTrack(
        from fileURL: URL,
        id: UUID? = nil,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        artworkURL: URL?,
        artworkData providedArtwork: Data? = nil,
        isExplicit: Bool
    ) async -> ImportResult {
        // 1. Security-scoped access
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            // 2. Copy + hash
            let provenance = try fileManager.importFile(from: fileURL)

            // 3. Check for duplicate
            let existingIDs = try trackRepo.existingIDs(forFileHash: provenance.fileHash)
            if let existingID = existingIDs.first,
               let existing = try trackRepo.fetch(id: existingID) {
                return .duplicate(existing)
            }

            return await saveOnline(
                provenance:  provenance,
                sourceURL:   fileURL,
                id:          id,
                title:       title,
                artistName:  artistName,
                albumTitle:  albumTitle,
                duration:    duration,
                artworkURL:  artworkURL,
                artworkData: providedArtwork,
                isExplicit:  isExplicit
            )
        } catch {
            return .failed(fileURL, error)
        }
    }

    /// Saves an online song with no audio: metadata, artwork, album, artist and the `sourceRef` to fetch it
    /// later. What saving a Discover song does. The row is `.online`; downloading is a separate action.
    public func saveOnlineTrack(
        sourceRef: String,
        id: UUID? = nil,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        artworkURL: URL?,
        artworkData providedArtwork: Data? = nil,
        isExplicit: Bool
    ) async -> ImportResult {
        // Already in the library under another id (an import, or a differently spelled catalogue save): report
        // it as a duplicate rather than add a second copy.
        if let existing = libraryService.ownedRecordingIndex
            .match(title: title, artistName: artistName, duration: duration),
           existing.id != id {
            return .duplicate(existing)
        }

        return await saveOnline(
            provenance:  .onlinePlaceholder(sourceRef: sourceRef),
            // Only names the file in a failure result; a placeholder has no file, so use the key.
            sourceURL:   URL(fileURLWithPath: "/\(sourceRef)"),
            id:          id,
            title:       title,
            artistName:  artistName,
            albumTitle:  albumTitle,
            duration:    duration,
            artworkURL:  artworkURL,
            artworkData: providedArtwork,
            isExplicit:  isExplicit
        )
    }

    /// Saves an online track list as one playlist ("add this mix to my library"). Rows are metadata-only.
    /// Not a loop over `saveOnlineTrack`, which does several network calls and a full refresh per song:
    /// rows are written in one pass with no network, and pictures are fetched after the playlist shows.
    /// `origin`/`ownerName` mark it as not the user's to edit. `id` makes a repeat save a no-op.
    /// Returns nil if no song could be saved.
    @discardableResult
    /// Merges two lists in proportion, keeping each list's order. Not `zip`: lengths differ, and the
    /// slider's ratio decides how often each side goes.
    static func interleaved(_ a: [UUID], _ b: [UUID]) -> [UUID] {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        var out: [UUID] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // Whichever side is furthest behind its share goes next.
            let aDue = i < a.count ? Double(i) / Double(a.count) : .infinity
            let bDue = j < b.count ? Double(j) / Double(b.count) : .infinity
            if aDue <= bDue { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        return out
    }

    public func saveOnlinePlaylist(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        artworkData: Data? = nil,
        coverURLs: [URL] = [],
        origin: PlaylistOrigin = .owned,
        ownerName: String? = nil,
        tracks: [OnlineTrack],
        coverBytes: [String: Data] = [:],
        /// Bakes the mix's colour band into the composed cover (see `MixCoverArt.Band`). Nil for playlists.
        coverBand: MixCoverArt.Band? = nil,
        // Library songs that belong in this mix too (see `MixGenerator`), merged in so it lands as one playlist.
        leadingTrackIDs: [UUID] = []
    ) -> Playlist? {
        if let existing = libraryService.playlist(id: id), !existing.isDeleted { return existing }

        // Scoped cost measurement; saving a mix is the slowest main-actor work in the app.
        MainThreadActivity.shared.resetCosts()
        defer {
            Task { @MainActor in
                // Long enough to catch the deferred bucket pass and the first sync-triggered refresh.
                try? await Task.sleep(for: .seconds(5))
                MainThreadActivity.shared.logReport("mix-save")
            }
        }

        let (saved, covers) = mixMainActivity("mix-save/write-tracks") {
            saveOnlineTracksLocally(tracks, coverBytes: coverBytes)
        }
        // Interleaved, not appended, so owned and new songs mix.
        let ids = Self.interleaved(leadingTrackIDs, saved)
        guard !ids.isEmpty else { return nil }

        var playlist = mixMainActivity("mix-save/create-playlist") { libraryService.createPlaylist(id: id,
                                                     name: name,
                                                     description: description,
                                                     artworkData: artworkData,
                                                     origin: origin,
                                                     ownerName: ownerName,
                                                     imported: true) }
        // Set wholesale: `addTrack` refuses a playlist the user may not edit, which a saved mix is.
        mixMainActivity("mix-save/set-tracks") { libraryService.setTracks(ids, inPlaylist: playlist.id) }
        playlist.trackIDs = ids

        // Past this line the playlist is in the library and the press is over.
        mixMainActivity("mix-save/schedule-sync") { scheduleSync() }
        libraryService.scheduleArtistImageBackfill()
        libraryService.scheduleArtworkBackfill(trackIDs:     saved,
                                               publishedBy:  nil,
                                               using:        onlineArtistImageClient,
                                               directCovers: covers)

        // A mix's 2x2 mosaic is flattened into the playlist's one cover, after the press (four downloads).
        if artworkData == nil, !coverURLs.isEmpty {
            let playlistID = playlist.id
            Task { [weak self] in
                guard let composed = await MixCoverArt.compose(from: coverURLs, band: coverBand),
                      let self,
                      // Not `displayArtwork == nil`: `setTracks` bakes a derived cover immediately, which would block the
                      // 2x2. Only a user-chosen cover is off limits.
                      self.libraryService.playlist(id: playlistID)?.coverKind != .chosen
                else { return }
                self.libraryService.setPlaylistArtwork(id: playlistID, data: composed)
                self.scheduleSync()
            }
        }
        return playlist
    }

    /// Writes an online track list to the library in one pass, no network, one refresh. Returns the ids
    /// in list order and the cover URLs to fetch later. `coverBytes` (keyed by online id) is artwork the
    /// caller already has, written with the row so it doesn't go grey.
    private func saveOnlineTracksLocally(
        _ tracks: [OnlineTrack],
        coverBytes: [String: Data] = [:]
    ) -> (ids: [UUID], covers: [UUID: URL]) {
        guard !tracks.isEmpty else { return ([], [:]) }

        let stored = (try? trackRepo.fetch(ids: tracks.map(\.stableTrackID))) ?? [:]
        // Songs the user already has under another id, so a mix doesn't duplicate them.
        var owned = mixMainActivity("mix-save/write-tracks/recording-index") { libraryService.ownedRecordingIndex }

        var ids: [UUID] = []
        var covers: [UUID: URL] = [:]
        var fresh: [Track] = []

        for track in tracks {
            let id = track.stableTrackID

            // A real row on this id is left alone; a share placeholder or deleted row gets overwritten.
            if let existing = stored[id], !existing.isUnresolvableShare, !existing.isDeleted {
                // A mix listing a song twice would put the id in the playlist twice.
                guard !ids.contains(id) else { continue }
                ids.append(id)
                if existing.artworkData == nil, let url = track.artworkURL { covers[id] = url }
                continue
            }

            // Already here under another id: point at the user's row and leave it untouched.
            if let existing = owned.match(title: track.title,
                                          artistName: track.artistName,
                                          duration: track.duration) {
                guard !ids.contains(existing.id) else { continue }
                ids.append(existing.id)
                if existing.artworkData == nil, let url = track.artworkURL { covers[existing.id] = url }
                continue
            }

            guard !ids.contains(id) else { continue }
            ids.append(id)

            var row = Track(
                id:          id,
                title:       track.displayTitle,
                artistName:  track.artistName,
                albumTitle:  track.albumTitle,
                duration:    track.duration,
                sync:        SyncMetadata(deviceID: deviceID),
                file:        .onlinePlaceholder(sourceRef: track.id)
            )
            row.artworkData = coverBytes[track.id]
            fresh.append(row)
            owned.insert(row)
            // Rows with a picture skip the download; refetching would also invalidate the cover on screen.
            if row.artworkData == nil, let url = track.artworkURL { covers[id] = url }
        }

        mixMainActivity("mix-save/write-tracks/repo-save") { try? trackRepo.save(fresh) }

        // Publish just these rows rather than a full `refresh()`, which was most of the freeze on save.
        mixMainActivity("mix-save/write-tracks/insert-locally") { libraryService.insertLocally(fresh) }

        // Album and artist buckets aren't needed for the playlist to appear, so they run after the press.
        // Artist photos stay with `scheduleArtistImageBackfill`.
        if !fresh.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Named for the hang watchdog: the reported freeze comes after the press returns.
                await mixPhase("mix-save/tail") {
                let batch = BucketBatch()

                // Pass one resolves every album and artist into `batch`, fetching only unseen rows. Four per chunk
                // so each main-actor hold stays short.
                for chunk in stride(from: 0, to: fresh.count, by: 4) {
                    let rows = fresh[chunk ..< min(chunk + 4, fresh.count)]
                    mixMainActivity("mix-save/buckets-chunk") {
                        for row in rows {
                            let album = try? self.updateAlbum(for: row, batch: batch)
                            try? self.updateArtist(for: row,
                                                   useArtistImageOnly: true,
                                                   album: album,
                                                   batch: batch)
                        }
                    }
                    await Task.yield()
                }

                // Pass two commits each distinct row once.
                let albums  = batch.dirtyAlbums.compactMap  { batch.albums[$0]  }
                let artists = batch.dirtyArtists.compactMap { batch.artists[$0] }
                for chunk in stride(from: 0, to: albums.count, by: 8) {
                    let rows = albums[chunk ..< min(chunk + 8, albums.count)]
                    mixMainActivity("mix-save/buckets-commit") {
                        RepositorySaveBatch.run(self.trackRepo.modelContext) {
                            for album in rows { try? self.albumRepo.save(album) }
                        }
                    }
                    await Task.yield()
                }
                for chunk in stride(from: 0, to: artists.count, by: 8) {
                    let rows = artists[chunk ..< min(chunk + 8, artists.count)]
                    mixMainActivity("mix-save/buckets-commit") {
                        RepositorySaveBatch.run(self.trackRepo.modelContext) {
                            for artist in rows { try? self.artistRepo.save(artist) }
                        }
                    }
                    await Task.yield()
                }

                self.libraryService.publishBuckets()
                }
            }
        }
        return (ids, covers)
    }

    /// Shared tail of both online saves: duplicate check on the stable id, artwork, track row, album,
    /// artist, then refresh, All Songs, sync and artist images.
    private func saveOnline(
        provenance: FileProvenance,
        sourceURL: URL,
        id: UUID?,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        artworkURL: URL?,
        artworkData providedArtwork: Data?,
        isExplicit: Bool
    ) async -> ImportResult {
        do {
            // The stable id comes from the online key, so a repeat save is a no-op, not a key collision. Except
            // over a share placeholder (which this save is meant to fill in) or a soft-deleted row (a request to
            // have it back): those fall through and upsert, keeping the id.
            if let id, let existing = try trackRepo.fetch(id: id),
               !existing.isUnresolvableShare, !existing.isDeleted {
                // A saved online song getting its audio: same row, now a file of the user's own.
                guard existing.isOnline, provenance.origin != .online else { return .duplicate(existing) }
                var upgraded = existing
                upgraded.file = provenance
                upgraded.duration = duration
                upgraded.sync.markModified()
                try trackRepo.save(upgraded)
                libraryService.scheduleRefresh()
                scheduleSync()
                return .imported(upgraded, MetadataReviewItem(imported: upgraded))
            }

            // 4. Artwork: use what's already loaded (e.g. a rebuilt OnlineTrack with no artworkURL), else download.
            var artworkData: Data? = ImageDownsampler.artworkJPEG(from: providedArtwork)
            if artworkData == nil, let artworkURL {
                let raw = try? await URLSession.shared.data(from: artworkURL).0
                artworkData = ImageDownsampler.artworkJPEG(from: raw)
            }

            // 5. Build domain track from the known metadata
            let track = Track(
                id:          id ?? UUID(),
                title:       title,
                artistName:  artistName,
                albumTitle:  albumTitle,
                duration:    duration,
                artworkData: artworkData,
                isExplicit:  isExplicit,
                sync:        SyncMetadata(deviceID: deviceID),
                file:        provenance
            )

            // 6. Persist track
            try trackRepo.save(track)

            // 7. Update or create album (grouped by primary artist)
            try updateAlbum(for: track)

            // 8. No photo yet, never the album cover. The backfill below fetches it; waiting on
            // it here held the save (and its checkmark) for seconds.
            try updateArtist(for: track, useArtistImageOnly: true)

            // 9. Refresh, coalesced; see `importTrack`.
            libraryService.scheduleRefresh()

            // 10. Debounced sync. Online rows upload metadata only; the resolver reproduces the audio anywhere.
            scheduleSync()
            libraryService.scheduleArtistImageBackfill()

            // 11. Passthrough candidate: the metadata is already correct, so no review.
            let candidate = EnrichmentCandidate(
                title:       title,
                artistName:  artistName != "Unknown Artist" ? artistName : nil,
                albumTitle:  albumTitle != "Unknown Album"  ? albumTitle : nil,
                year:        nil,
                genre:       nil,
                trackNumber: nil,
                confidence:  1.0,
                source:      .existingMetadata
            )

            // No lookup: online imports arrive with the catalogue's tags.
            return .imported(track, MetadataReviewItem(track: track, candidate: candidate))

        } catch {
            return .failed(sourceURL, error)
        }
    }

    // MARK: - Batch Import

    /// Import multiple files; returns one result per URL. Songs picked in Add Music are liked unless
    /// the account sends imports to All Songs. Watched folders use `importTrack` and never are.
    public func importTracks(from urls: [URL]) async -> [ImportResult] {

        SupabaseSyncService.allowBulk("file-import")
        let signpost = MixSignpost.importing.beginInterval("import-files",
                                                           id: MixSignpost.importing.makeSignpostID())
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MixSignpost.importing.endInterval("import-files", signpost)
            MixLog.importing.notice("import-files: \(urls.count, privacy: .public) file(s) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms")
        }
        var results: [ImportResult] = []
        for url in urls {
            let result = await importTrack(from: url)
            results.append(result)
        }
        let added = results.compactMap { r -> UUID? in
            if case .imported(let track, _) = r { return track.id }
            return nil
        }
        if PlaylistMetadataService.shared.likesImports {
            SupabaseSyncService.allowBulk("file-import")
            libraryService.addTracks(ids: added, toPlaylist: Playlist.favouritesID)
        }
        // One refresh for the whole batch; a no-op if the coalesced one already ran.
        libraryService.flushPendingRefresh()
        return results
    }

    // MARK: - Apply Enrichment

    /// What the review sheet wants done with the cover. Three states because "untouched" and "cleared"
    /// both arrive with no bytes.
    public enum ArtworkChoice: Sendable {
        /// No edit: fall back to the candidate's remote cover.
        case keep
        /// The user picked an image in the sheet.
        case replace(Data)
        /// The user cleared the cover and wants none.
        case remove
    }

    /// Writes confirmed metadata and artwork to the stored track, then re-links its album and artist.
    /// - Parameter primaryArtistOverride: files the track under this artist instead of the parsed one.
    public func applyEnrichment(
        trackID:               UUID,
        title:                 String,
        artistName:            String,
        albumTitle:            String,
        year:                  Int?,
        genre:                 String?,
        artworkURL:            URL?,
        artistImageURL:        URL? = nil,
        primaryArtistOverride: String? = nil,
        artwork:               ArtworkChoice = .keep
    ) async {
        // 1. Fetch the cover and artist photo concurrently. The cover is skipped unless the sheet left it open.
        var artworkData:      Data? = nil
        var artistImageData:  Data? = nil
        await withTaskGroup(of: Void.self) { group in
            if case .keep = artwork, let url = artworkURL {
                group.addTask {
                    let raw = try? await URLSession.shared.data(from: url).0
                    artworkData = ImageDownsampler.artworkJPEG(from: raw)
                }
            }
            if let url = artistImageURL {
                group.addTask {
                    let raw = try? await URLSession.shared.data(from: url).0
                    artistImageData = ImageDownsampler.artworkJPEG(from: raw)
                }
            }
        }
        if case .replace(let picked) = artwork { artworkData = ImageDownsampler.artworkJPEG(from: picked) }

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
        if case .remove = artwork {
            track.artworkData = nil
        } else if let data = artworkData {
            track.artworkData = data
        }
        track.sync.markModified()
        try? trackRepo.save(track)

        if ExportManager.shared.syncMetadataToDisk {
            ExportManager.shared.updateMetadataOnDisk(for: track, oldArtist: oldArtist, oldTitle: oldTitle)
        }

        // 4. Re-link by actual track membership, not by guessing the old bucket from the name.
        let primary = primaryArtistOverride ?? ImportService.primaryArtistName(from: artistName)
        try? relinkTrack(
            id:            trackID,
            toAlbumTitle:  albumTitle,
            primaryArtist: primary,
            artwork:       artworkData ?? track.artworkData,
            artistArtwork: artistImageData,
            year:          year
        )

        // 5. Refresh and sync; a re-filed track may need a photo for a new artist.
        libraryService.refresh()
        scheduleSync()
        libraryService.scheduleArtistImageBackfill()
    }

    // MARK: - Rebuild All Groupings

    /// Re-files every track under its correct primary artist and album. A one-time repair: tracks with a
    /// feature separator are split; solo tracks only move if they have no bucket at all.
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
        // Always sweep: relinkTrack may have returned early without cleaning up.
        cleanupEmptyBuckets()
        libraryService.refresh()
        libraryService.scheduleArtistImageBackfill()
    }

    // MARK: - Move to Artist Folder (post-import reassignment)

    /// Re-files a track under a different artist folder without changing its display artist.
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
        // The destination folder may not have existed a moment ago.
        libraryService.scheduleArtistImageBackfill()
    }

    // MARK: - Sync Scheduling

    private func scheduleSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task {
            // 1s debounce: keep resetting while tracks arrive, then fire once.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            MixLog.importing.debug("[ImportService] Auto-sync triggered after import")
            await onSyncNeeded?()
        }
    }

    // MARK: - Private Helpers

    /// Creates or updates the album for `track`, grouped by primary artist.
    @discardableResult
    private func updateAlbum(for track: Track, batch: BucketBatch? = nil) throws -> Album {
        let primary = ImportService.primaryArtistName(from: track.artistName)
        let key = BucketBatch.albumKey(title: track.albumTitle, artistName: primary)

        var album: Album
        if let cached = batch?.albums[key] {
            album = cached
        } else {
            album = try albumRepo.findOrCreate(
                title:      track.albumTitle,
                artistName: primary,
                deviceID:   deviceID
            )
        }

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
            if batch == nil { try albumRepo.save(album) } else { batch?.dirtyAlbums.insert(key) }
        }

        batch?.albums[key] = album
        return album
    }

    /// Creates or updates the artist for `track`, grouped by primary artist.
    /// - Parameters:
    /// - artistImageData: the artist's Spotify photo, if resolved.
    /// - useArtistImageOnly: online imports use only `artistImageData`; local imports fall back to album art.
    private func updateArtist(for track: Track,
                              artistImageData: Data? = nil,
                              useArtistImageOnly: Bool = false,
                              album: Album? = nil,
                              batch: BucketBatch? = nil) throws {
        let primary = ImportService.primaryArtistName(from: track.artistName)
        // Every credited artist gets a row and the track, so a feature shows on both pages.
        for credited in ImportService.creditedArtists(from: track.artistName) {
            try attachTrack(track,
                            toArtistNamed: credited,
                            albumOwner: primary,
                            album: album,
                            batch: batch,
                            artistImageData: artistImageData,
                            useArtistImageOnly: useArtistImageOnly)
        }
    }

    private func attachTrack(_ track: Track,
                             toArtistNamed name: String,
                             albumOwner primary: String,
                             album knownAlbum: Album? = nil,
                             batch: BucketBatch? = nil,
                             artistImageData: Data?,
                             useArtistImageOnly: Bool) throws {
        var artist: Artist
        if let cached = batch?.artists[name] {
            artist = cached
        } else {
            artist = try artistRepo.findOrCreate(name: name, deviceID: deviceID)
        }

        var modified = false

        if !artist.trackIDs.contains(track.id) {
            artist.trackIDs.append(track.id)
            modified = true
        }

        // `knownAlbum` is the row `updateAlbum` just resolved; don't fetch it again per artist.
        let album = try knownAlbum ?? albumRepo.find(title: track.albumTitle, artistName: primary)
        if let album, !artist.albumIDs.contains(album.id) {
            artist.albumIDs.append(album.id)
            modified = true
        }

        // The photo belongs to the primary artist only. Others get the album cover as a stand-in (local
        // imports only) until `LibraryService.backfillArtistImages()` replaces it.
        if artist.artworkData == nil {
            if let photo = artistImageData,
               name.caseInsensitiveCompare(primary) == .orderedSame {
                artist.artworkData = photo
                modified = true
            } else if !useArtistImageOnly, let art = track.artworkData {
                artist.artworkData = art
                modified = true
            }
        }

        if modified {
            artist.sync.markModified()
            if batch == nil { try artistRepo.save(artist) } else { batch?.dirtyArtists.insert(name) }
        }

        batch?.artists[name] = artist
    }

    /// One row per distinct album and artist for a whole mix save, fetched and committed once each
    /// instead of per track.
    final class BucketBatch {
        var albums:  [String: Album]  = [:]
        var artists: [String: Artist] = [:]
        var dirtyAlbums:  Set<String> = []
        var dirtyArtists: Set<String> = []

        /// `\u{1}` can't appear in a title or name, so the key can't collide.
        static func albumKey(title: String, artistName: String) -> String {
            "\(title)\u{1}\(artistName)"
        }
    }

    /// Moves a track to the correct album and artist bucket, found by actual membership so it works after
    /// bad enrichments:
    /// 1. Find every album/artist containing this track.
    /// 2. Remove it from those that aren't the target.
    /// 3. Add it to the target, creating it if needed.
    /// 4. Soft-delete any buckets left empty.
    private func relinkTrack(
        id trackID:    UUID,
        toAlbumTitle:  String,
        primaryArtist: String,
        artwork:       Data?,          // album/track artwork
        artistArtwork: Data? = nil,  // artist photo, separate from album art
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

        // Nothing to do?
        if inTargetAlbum && inTargetArtist && wrongAlbums.isEmpty && wrongArtists.isEmpty {
            // Already correct: propagate artwork, always overwriting so iTunes/Deezer beats embedded art.
            if let art = artwork, var a = holdingAlbums.first {
                a.artworkData = art; a.sync.markModified(); try? albumRepo.save(a)
            }
            if let artistArt = artistArtwork {
                // A real artist photo: overwrite.
                if var a = holdingArtists.first {
                    a.artworkData = artistArt; a.sync.markModified(); try? artistRepo.save(a)
                }
            } else if let albumArt = artwork, var a = holdingArtists.first, a.artworkData == nil {
                // Album art only if the artist has none.
                a.artworkData = albumArt; a.sync.markModified(); try? artistRepo.save(a)
            }
            return
        }

        // Remove from wrong album buckets
        for var album in wrongAlbums {
            album.trackIDs.removeAll { $0 == trackID }
            if album.trackIDs.isEmpty {
                try? albumRepo.softDelete(id: album.id)
            } else {
                album.sync.markModified()
                try? albumRepo.save(album)
            }
        }

        // Add to target album
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

        // Resolve target album ID for artist linking
        let targetAlbumID = (try? albumRepo.fetchAll())?.first(where: {
            $0.title == toAlbumTitle && $0.artistName == primaryArtist
        })?.id

        // Remove from wrong artist buckets, tracking emptied albums to unlink them.
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

        // Add to target artist
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
        // Prefer the artist photo; album art only if the artist has no image.
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

        // Sweep orphaned empty buckets from previous bad states
        cleanupEmptyBuckets()
    }

    /// Soft-deletes any album or artist with no tracks left. Runs after every relink.
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
