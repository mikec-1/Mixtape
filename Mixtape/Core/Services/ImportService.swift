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
// explicit "featuring" separator (" ft. ", " feat. ", " featuring ").
// " & " and " x " are NOT separators — they appear in real band names
// ("Simon & Garfunkel"), so those stay intact.
// "Pitbull ft. Kesha"   → filed under "Pitbull"
// "Simon & Garfunkel"   → filed under "Simon & Garfunkel"
// The full artist string is still stored on the Track for display purposes.
// The user can override the primary artist in the metadata review sheet
// ("Filed Under" field) or post-import via "Move to Artist Folder…".

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

    /// Resolves artist profile photos via Spotify (never Deezer/album art) for
    /// online imports. Self-contained client; reuses one token across imports.
    private let onlineArtistImageClient = ITunesSearchClient(spotifyClient: SpotifyClient())

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
    ///   "Simon & Garfunkel"   → "Simon & Garfunkel"
    ///   "Adele"               → "Adele"
    public nonisolated static func primaryArtistName(from artistName: String) -> String {
        splitArtist(from: artistName).primary
    }

    /// Splits "Pitbull ft. Kesha" into ("Pitbull", "Kesha").
    /// Returns (artistName, nil) when no featured separator is found.
    ///
    /// Deliberately splits ONLY on explicit feature markers — never on " & " or
    /// " x ". Those appear in real band names ("Simon & Garfunkel", "Earth,
    /// Wind & Fire"), and since this function decides which artist bucket a
    /// track is *filed under* (and that filing syncs to every device), breaking
    /// a band name is a much worse failure than filing a one-off "A & B" collab
    /// under the duo string. Mirrors the separator policy of `splitArtists`.
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

    /// Splits a display artist string into an ORDERED list of individual artist
    /// names, breaking ONLY on feature markers (" feat. ", " feat ", " ft. ",
    /// " ft ", " featuring "), case-insensitive. Unlike `splitArtist`, this does
    /// NOT split on "&", " x ", or commas — doing so would wrongly break group
    /// names like "Earth, Wind & Fire" or "Tyler, the Creator".
    ///
    /// Used for per-artist tappable display so each contributor opens its own
    /// profile. A featured segment may itself contain multiple artists joined by
    /// the same markers (rare), so the split is applied recursively.
    ///
    /// Examples:
    ///   "Drake feat. 21 Savage"        → ["Drake", "21 Savage"]
    ///   "Pitbull ft. Kesha"            → ["Pitbull", "Kesha"]
    ///   "Earth, Wind & Fire"           → ["Earth, Wind & Fire"]
    ///   "Adele"                        → ["Adele"]
    /// Group names that legitimately contain a comma or ampersand. Matched
    /// case-insensitively against the *whole* credit string before any splitting,
    /// so these stay as one artist. Not exhaustive — it can't be — but it covers
    /// the names that actually collide in practice.
    private static let indivisibleActs: Set<String> = [
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

    /// Every artist credited on a track, as separate names.
    ///
    /// This is what decides which artist *buckets* a track is filed under, so
    /// "c4rl, Yungpalo" has to become two artists rather than one artist whose
    /// name happens to contain a comma.
    ///
    /// Separator policy, in order of how much it can hurt to get wrong:
    ///   - Feature markers ("feat.", "ft.", "featuring") always split. Unambiguous.
    ///   - " x " always splits. It only ever appears as a collab marker.
    ///   - Commas split, and once a comma is present " & " / " and " split too —
    ///     that's the "A, B & C" credit format.
    ///   - A lone " & " with no comma anywhere does NOT split: "Simon & Garfunkel"
    ///     and "Hall & Oates" are far more common than one-off "A & B" collabs.
    ///
    /// `indivisibleActs` overrides all of it for known comma-containing bands.
    ///
    /// Examples:
    ///   "c4rl, Yungpalo"      → ["c4rl", "Yungpalo"]
    ///   "Yungpalo, c4rl, YT"  → ["Yungpalo", "c4rl", "YT"]
    ///   "Drake feat. 21 Savage" → ["Drake", "21 Savage"]
    ///   "Simon & Garfunkel"   → ["Simon & Garfunkel"]
    ///   "Earth, Wind & Fire"  → ["Earth, Wind & Fire"]
    public static func creditedArtists(from artistName: String) -> [String] {
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
                // A known band name that survived to this point (e.g. as the
                // featured half of a credit) must not be broken up either.
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

    /// Every artist to *print* for a track: the stored credit, plus any feature
    /// the title names.
    ///
    /// Deezer, where Discover gets its metadata, credits one artist per song —
    /// the main one. Everyone else is in the title instead ("FRANCHISE (feat.
    /// Future, Young Thug & M.I.A.) - REMIX"), which is why the player bar could
    /// print "Travis Scott" under a title naming three other people.
    ///
    /// Read back out of the title rather than written into `artistName`, and
    /// deliberately so. The stored credit is half of an online track's identity:
    /// `OnlineTrack.id` is "title|artist" and `stableTrackID` hashes it, so a
    /// song whose credit string grew would hash to a *different* track — a
    /// second row in the library, split play counts, and a cache miss on a file
    /// already downloaded. It also decides which artist bucket a track is filed
    /// under, and a featured name is not a filing decision. This is display
    /// only, and every caller is a now-playing surface.
    ///
    /// A credit that already lists everybody (Spotify's import joins all of a
    /// track's artists) is returned untouched — the merge is case-insensitive.
    public static func displayArtists(title: String, artistName: String) -> [String] {
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

    /// The song's name with a printed feature credit taken back off.
    ///
    ///   "Ran To Atlanta (feat. Future & Molly Santana)" → "Ran To Atlanta"
    ///   "FRANCHISE (feat. Future) - REMIX"              → unchanged
    ///
    /// The inverse of `OnlineTrack.displayTitle`, and it exists for exactly one
    /// reason: `displayTitle` is what gets *stored* on the library row, while the
    /// row's identity — its id, its `sourceRef`, its cache stem — was hashed from
    /// the source's bare title. So any key rebuilt from `track.title` after that
    /// change stopped hashing to the row's own id, and every caller that rebuilds
    /// one has to be able to ask for this spelling too.
    ///
    /// Only a *bracketed* credit is removed, and only when a marker opens the
    /// group. An unbracketed credit — "Type Shit feat. Playboi Carti" — is left
    /// alone on purpose: `displayTitle` never appends that shape, so a title
    /// wearing one came from the source with it and is part of the identity.
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
        // A title that was *only* a credit is not a title. Better to leave the
        // original standing than to hand identity an empty string.
        return cleaned.isEmpty ? title : cleaned
    }

    /// The names inside a title's feature credit.
    ///
    ///   "FRANCHISE (feat. Future, Young Thug & M.I.A.) - REMIX"
    ///       → ["Future", "Young Thug", "M.I.A."]
    ///   "Levitating (Remix)"  → []
    ///
    /// Only what follows a feature marker is read. A title is not a credit
    /// string — everything else in it is the name of the song.
    public static func featuredArtists(inTitle title: String) -> [String] {
        guard let marker = featureMarker(in: title) else { return [] }
        var segment = String(title[marker...])
        // A marker opened inside brackets ends with them, so "- REMIX" and
        // anything else trailing the group isn't read as a person.
        if let close = segment.firstIndex(where: { $0 == ")" || $0 == "]" }) {
            segment = String(segment[..<close])
        }
        // …and a marker that was NOT bracketed has to end somewhere too. Deezer
        // titles are not consistently punctuated, so "Type Shit feat. Playboi
        // Carti - Bonus Track" ran to the end of the string and printed a credit
        // for an artist called "Playboi Carti - Bonus Track" — a name that
        // exists nowhere, and on iOS a tappable one that opened an empty page.
        // A dash, or a bracket group opening after the names, ends the credit.
        if let stop = segment.range(of: " - ") ?? segment.range(of: " \u{2013} ")
            ?? segment.range(of: "(") ?? segment.range(of: "[") {
            segment = String(segment[..<stop.lowerBound])
        }
        return splitFeatureCredit(segment)
    }

    /// Where the featured names start, or nil. Markers only count at the start
    /// of a word — otherwise "Drift" and "Aftermath" would each open one.
    private static func featureMarker(in title: String) -> String.Index? {
        // "with" only counts immediately inside brackets: Spotify writes
        // "(with Ariana Grande)", but plain "with" in a title is usually the
        // title ("Dancing With Myself").
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

    /// Splits the inside of a feature credit. Unlike `creditedArtists`, "&" and
    /// "and" always split here: inside "feat. …" they join collaborators, and a
    /// band whose name contains one is far less likely than a second guest.
    private static func splitFeatureCredit(_ segment: String) -> [String] {
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
            // Whitespace and dashes only. A blanket punctuation trim would
            // rewrite "M.I.A." to "M.I.A", which is its own kind of mangling.
            let name = part.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}"))
            // A person's name has letters or digits in it. Anything left over
            // from splitting that doesn't — a stray dash, a lone bracket — is
            // punctuation, not a guest, and printing it invents an artist.
            guard !name.isEmpty, name.count <= 60,
                  name.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

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
                // Embedded covers are whatever the tagger felt like: a 3 MB
                // front sleeve is common, and the library holds every one of
                // them in memory at once. Shrink on the way in.
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

            // 9. Refresh in-memory library — coalesced, because this runs once
            //     per song and a full refresh re-reads the entire library.
            //     `importTracks` flushes it when the batch ends.
            libraryService.scheduleRefresh()

            // 11. Schedule a debounced sync so the server sees the new tracks
            //     without the caller having to think about it. The artist rows
            //     just created are wearing this track's album cover; the backfill
            //     replaces those with real profile photos once the batch settles.
            scheduleSync()
            libraryService.scheduleArtistImageBackfill()

            // 12. Hand back something reviewable straight away.
            //
            //     This step used to await the iTunes lookup — four storefronts,
            //     an artist search and a Deezer photo, all before the import
            //     was allowed to finish. On a batch that's the whole wait, and
            //     the sheet arrived so late the user had already moved on. The
            //     lookup now belongs to the sheet, which opens on the local
            //     reading and updates itself when the answer comes back.
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

    /// Import an already-downloaded audio file using caller-supplied metadata.
    ///
    /// This is the online variant of `importTrack(from:)` used by the Discover
    /// "Add to Library" flow. The file is fetched via yt-dlp and has no (or
    /// garbage) embedded tags, so instead of parsing the file we trust the
    /// title/artist/album/artwork already known from the online search result.
    /// No enrichment review is run — the metadata is treated as authoritative.
    /// Pass `id` to keep the saved track's identity equal to the `OnlineTrack`'s
    /// `stableTrackID`. Without it the library row gets a fresh UUID, and every
    /// "is this playing song in my library?" check against the online track's id
    /// answers no forever — which left the save button reverting to a plus and
    /// the player-bar heart inert on a song that had in fact been saved.
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

    /// Save an online song to the library without any audio: metadata, artwork,
    /// album, artist, and the `sourceRef` needed to fetch it again on demand.
    ///
    /// This is what saving a Discover song does. The row is explicitly `.online`,
    /// so playback resolves it, the badge shows it as an online song rather than
    /// a downloaded one, and sync leaves its (nonexistent) audio alone. Making a
    /// permanent copy is a separate action the user takes deliberately —
    /// `DownloadManager` — and it doesn't change what this row *is*.
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
        // The library's own copy, if it has one under a different id — an
        // imported file, or this song saved from a catalogue that spells it
        // differently. Saving on top of that is what put two of the same song in
        // the library, so the honest answer is the one the id check already
        // gives for an exact match: you have this.
        if let existing = libraryService.ownedRecordingIndex
            .match(title: title, artistName: artistName, duration: duration),
           existing.id != id {
            return .duplicate(existing)
        }

        return await saveOnline(
            provenance:  .onlinePlaceholder(sourceRef: sourceRef),
            // Only used to name the file in a failure result; a placeholder has
            // no file, so the song's own key is the most useful thing to report.
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

    /// Saves a whole online track list to the library as one playlist — what
    /// "add this mix to my library" does.
    ///
    /// Every song is a metadata-only row, so a mix costs no disk and no audio:
    /// the rows carry their source keys and resolve on demand exactly like a
    /// song saved from Discover.
    ///
    /// It is deliberately *not* a loop over `saveOnlineTrack`. That call is
    /// right for one song and badly wrong for twenty-five: per song it
    /// downloads a cover, asks Spotify for an artist photo, downloads that too,
    /// and then re-reads the entire library — three network round trips and a
    /// full sweep, serially, with the user watching a spinner the whole time.
    /// None of it is needed for the playlist to exist. So the rows are written
    /// in one pass with no network at all, and every picture is fetched
    /// afterwards, once the playlist is already on screen.
    ///
    /// `origin`/`ownerName` are passed straight through to the playlist, which is
    /// how the result knows it isn't the user's to edit.
    ///
    /// Returns the new playlist, or nil if not one song could be saved — a mix
    /// that produced an empty playlist is a failure worth reporting, not an empty
    /// row to leave in someone's library.
    /// `id` pins the playlist's identity so saving the same thing twice is a
    /// no-op rather than a second copy — a mix derives one from its contents.
    @discardableResult
    /// Two lists shuffled together in proportion, order preserved within each.
    ///
    /// Not `zip`: the two halves are rarely the same length, and the ratio the
    /// user chose on the slider is exactly what decides how often one side
    /// gets a turn.
    static func interleaved(_ a: [UUID], _ b: [UUID]) -> [UUID] {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        var out: [UUID] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // Whichever side is furthest behind where its share says it should
            // be goes next.
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
        /// Bakes the mix's colour band into the composed cover — see
        /// `MixCoverArt.Band`. Nil for ordinary playlists.
        coverBand: MixCoverArt.Band? = nil,
        // Songs already in the library that belong in this playlist too, played
        // first. A generated mix is part catalogue and part the user's own
        // shelf (see `MixGenerator`), and it has to land as one playlist rather
        // than as two halves the user is left to merge.
        leadingTrackIDs: [UUID] = []
    ) -> Playlist? {
        if let existing = libraryService.playlist(id: id), !existing.isDeleted { return existing }

        // Scoped measurement. Saving a mix is the slowest thing the app does on
        // the main actor and three rounds of reasoning about it from the outside
        // got the wrong answer twice, so the spans below report themselves.
        MainThreadActivity.shared.resetCosts()
        defer {
            Task { @MainActor in
                // Late enough to catch the deferred bucket pass and the first
                // refresh the sync tail triggers, which is where a press that
                // "ends" still leaves the app crawling.
                try? await Task.sleep(for: .seconds(5))
                MainThreadActivity.shared.logReport("mix-save")
            }
        }

        let (saved, covers) = mixMainActivity("mix-save/write-tracks") {
            saveOnlineTracksLocally(tracks, coverBytes: coverBytes)
        }
        // Interleaved rather than appended: a mix that plays twelve songs you
        // own and then twelve you don't is two playlists in a trenchcoat.
        let ids = Self.interleaved(leadingTrackIDs, saved)
        guard !ids.isEmpty else { return nil }

        var playlist = mixMainActivity("mix-save/create-playlist") { libraryService.createPlaylist(id: id,
                                                     name: name,
                                                     description: description,
                                                     artworkData: artworkData,
                                                     origin: origin,
                                                     ownerName: ownerName,
                                                     imported: true) }
        // Set wholesale rather than one `addTrack` at a time: that call refuses a
        // playlist the user may not edit, and a saved mix is precisely that from
        // the moment it exists.
        mixMainActivity("mix-save/set-tracks") { libraryService.setTracks(ids, inPlaylist: playlist.id) }
        playlist.trackIDs = ids

        // Past this line the playlist is in the library and the press is over.
        mixMainActivity("mix-save/schedule-sync") { scheduleSync() }
        libraryService.scheduleArtistImageBackfill()
        libraryService.scheduleArtworkBackfill(trackIDs:     saved,
                                               publishedBy:  nil,
                                               using:        onlineArtistImageClient,
                                               directCovers: covers)

        // A playlist has one cover and every view in the app reads that one
        // field, so a mix's four-up mosaic has to be flattened into it — after
        // the press, because it costs four downloads and the playlist is
        // already on screen without it.
        if artworkData == nil, !coverURLs.isEmpty {
            let playlistID = playlist.id
            Task { [weak self] in
                guard let composed = await MixCoverArt.compose(from: coverURLs, band: coverBand),
                      let self,
                      // Not `displayArtwork == nil`: `setTracks` bakes a derived
                      // cover the moment the mix lands, and at that point only a
                      // handful of songs have artwork — so the bake is a single
                      // picture and it used to block the real 2×2 forever. Only
                      // a cover the user chose is off limits.
                      self.libraryService.playlist(id: playlistID)?.coverKind != .chosen
                else { return }
                self.libraryService.setPlaylistArtwork(id: playlistID, data: composed)
                self.scheduleSync()
            }
        }
        return playlist
    }

    /// Writes a whole online track list to the library in one pass, with no
    /// network calls and one refresh.
    ///
    /// Returns the track ids in the list's own order, plus the cover URLs worth
    /// fetching once the caller has something on screen.
    /// `coverBytes`, keyed by the online track's own id, is artwork the caller
    /// already has in hand — a mix page fetches every cover to draw its list
    /// before anything is saved. Writing those bytes with the row is the
    /// difference between a saved song keeping the picture the user was just
    /// looking at and going grey until a download replaces it.
    private func saveOnlineTracksLocally(
        _ tracks: [OnlineTrack],
        coverBytes: [String: Data] = [:]
    ) -> (ids: [UUID], covers: [UUID: URL]) {
        guard !tracks.isEmpty else { return ([], [:]) }

        let stored = (try? trackRepo.fetch(ids: tracks.map(\.stableTrackID))) ?? [:]
        // The songs the user already has under some *other* id: an imported
        // file, or the same recording saved from a catalogue that spells it
        // differently. Without this a mix full of songs already in the library
        // doubles every one of them.
        var owned = mixMainActivity("mix-save/write-tracks/recording-index") { libraryService.ownedRecordingIndex }

        var ids: [UUID] = []
        var covers: [UUID: URL] = [:]
        var fresh: [Track] = []

        for track in tracks {
            let id = track.stableTrackID

            // Same rule as the single-song save: a real row already standing on
            // this id is left alone, but a share placeholder or a row the user
            // has deleted is exactly what this save is meant to write over.
            if let existing = stored[id], !existing.isUnresolvableShare, !existing.isDeleted {
                // A mix listing the same song twice would otherwise put the same
                // id in the playlist twice, which nothing downstream expects.
                guard !ids.contains(id) else { continue }
                ids.append(id)
                if existing.artworkData == nil, let url = track.artworkURL { covers[id] = url }
                continue
            }

            // Already here under another id. The playlist points at the row the
            // user owns rather than a copy of it — nothing about that row is
            // touched, downloads included.
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
            // A row that already has its picture needs no download. Queuing one
            // anyway would fetch the same bytes again and, worse, invalidate the
            // cover that is already on screen to replace it with itself.
            if row.artworkData == nil, let url = track.artworkURL { covers[id] = url }
        }

        mixMainActivity("mix-save/write-tracks/repo-save") { try? trackRepo.save(fresh) }

        // Publish the rows we just wrote, rather than re-reading the whole
        // library to discover them. `refresh()` here was the bulk of the ten
        // second freeze on saving a mix: it re-fetches every track, album and
        // artist, runs the repair sweeps and rebuilds All Songs, all on the
        // main actor inside the button press, to learn about twenty-four rows
        // this function is already holding.
        mixMainActivity("mix-save/write-tracks/insert-locally") { libraryService.insertLocally(fresh) }

        // Album and artist buckets are the other half of the old refresh, and
        // they are not needed for the playlist to appear — nothing on the
        // screen the user is about to see reads them. Off the press, then, so
        // the press itself ends now. Artist photos stay with
        // `scheduleArtistImageBackfill`: asking Spotify for one per song is
        // most of what made this slow in the first place.
        if !fresh.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ten at a time, each chunk one commit. Two costs were being
                // paid per row: a `ModelContext` commit for the album and one
                // per credited artist — tens of milliseconds each, individually
                // under the instrumentation threshold, together the second or
                // two the app sat frozen after the checkmark appeared. The
                // chunk boundary is where the yield goes, so the main actor
                // still gets let go of regularly.
                // Named for the watchdog: the freeze the user reports comes
                // *after* the press returns, so none of the spans inside
                // `saveOnlinePlaylist` can ever cover it.
                await mixPhase("mix-save/tail") {
                let batch = BucketBatch()

                // Pass one resolves every album and artist into `batch`,
                // touching the store only for rows it has not seen yet. Four
                // at a time rather than ten: the chunk is the unit the main
                // actor is held for, and ten rows of fetching ran to ~109 ms
                // — thirteen dropped frames on a 120 Hz screen.
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

    /// Shared tail of both online saves: duplicate check on the stable id,
    /// artwork, the track row, album, artist, and the follow-up work (refresh,
    /// All Songs, sync, artist images). Everything above this differs only in
    /// whether there's a file behind the row.
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
            // The stable id is derived from the online key, so a song saved from
            // Discover once already owns it. Saving again is a no-op, not a
            // primary-key collision.
            //
            // Unless what's sitting on the id is a placeholder. A shared playlist
            // mints those from a collaborator's snapshot under the same stable
            // id, so "already exists" here is exactly the row this save is meant
            // to fill in — reporting it as a duplicate would refuse the download
            // that was supposed to make the song playable and leave it greyed out
            // forever. Falling through upserts over it, which keeps the id and so
            // keeps the playlist's ordering intact.
            //
            // A soft-deleted row is the same story for the same reason. Saving a
            // song the library is currently hiding is a request to have it back,
            // and answering "you already have this" about something the user
            // cannot see is the least useful true statement available — it left
            // re-adding a deleted Discover song doing visibly nothing at all.
            if let id, let existing = try trackRepo.fetch(id: id),
               !existing.isUnresolvableShare, !existing.isDeleted {
                return .duplicate(existing)
            }

            // 4. Download artwork — online search artwork is small, so we fetch
            //    it eagerly so albums/artists get cover art on first import.
            // Prefer already-loaded artwork (e.g. a Home/now-playing track whose
            // rebuilt OnlineTrack carries no artworkURL); fall back to downloading.
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

            // 8. Resolve the artist's Spotify profile picture (never the album
            //    cover) so the saved artist gets a real photo, not the song's art.
            let primaryArtist = ImportService.primaryArtistName(from: artistName)
            var artistImageData: Data? = nil
            if let imgURL = await onlineArtistImageClient.artistImageURL(for: primaryArtist) {
                let raw = try? await URLSession.shared.data(from: imgURL).0
                artistImageData = ImageDownsampler.artworkJPEG(from: raw)
            }

            // 9. Update or create artist (primary artist only). For online imports
            //    the artwork comes ONLY from the Spotify photo above — fall back to
            //    the placeholder (nil) rather than the album cover.
            try updateArtist(for: track, artistImageData: artistImageData, useArtistImageOnly: true)

            // 10. Refresh in-memory library — coalesced; see `importTrack`.
            libraryService.scheduleRefresh()

            // 11. Schedule a debounced sync so the server sees the new track.
            //      Metadata and artwork always go up; the audio only follows for
            //      a file the user actually imported. An online row has nothing
            //      to upload and nothing worth uploading — the resolver produces
            //      that audio on demand, on any device, for free.
            scheduleSync()
            // Featured artists don't get the headliner's photo above, so they
            // still need one of their own.
            libraryService.scheduleArtistImageBackfill()

            // 12. Passthrough candidate from the known metadata. We already have
            //      correct tags, so no enrichment review is needed.
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

            // No lookup: an online import arrives with the catalogue's own
            // tags, so there is nothing iTunes could tell us that's better.
            return .imported(track, MetadataReviewItem(track: track, candidate: candidate))

        } catch {
            return .failed(sourceURL, error)
        }
    }

    // MARK: - Batch Import

    /// Import multiple files; returns one result per URL.
    public func importTracks(from urls: [URL]) async -> [ImportResult] {
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
        // One pass over the library for the whole batch rather than one per
        // song. Unconditional: it costs nothing if the coalesced refresh has
        // already run on its own.
        libraryService.flushPendingRefresh()
        return results
    }

    // MARK: - Apply Enrichment

    /// Writes confirmed metadata + downloaded artwork back to the stored track,
    /// then re-links the track to the correct album and artist folders.
    ///
    /// - Parameter primaryArtistOverride: If supplied, the track is filed under
    ///   this artist instead of the auto-parsed primary artist. Used when the
    ///   user manually specifies the Artist value in the review sheet.
    /// What the review sheet wants done with the cover.
    ///
    /// Three states rather than two, because "the user didn't touch it" and
    /// "the user pressed the bin" both arrive carrying no bytes. Collapsing
    /// them into `Data?` is what would make the bin a no-op.
    public enum ArtworkChoice: Sendable {
        /// No edit — fall back to the candidate's remote cover as before.
        case keep
        /// The user picked an image in the sheet.
        case replace(Data)
        /// The user cleared the cover and wants none.
        case remove
    }

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
        // 1. Download album artwork and artist profile photo concurrently (if URLs provided).
        //    The cover download is skipped unless the sheet left the choice
        //    open — fetching one only to overwrite or discard it is a round
        //    trip the user waits on for nothing.
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

        // 5. Refresh + sync. Confirming metadata can re-file the track under a
        //    different (possibly brand new) artist, so photos are checked again.
        libraryService.refresh()
        scheduleSync()
        libraryService.scheduleArtistImageBackfill()
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
        libraryService.scheduleArtistImageBackfill()
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
        // The destination folder may not have existed a moment ago.
        libraryService.scheduleArtistImageBackfill()
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

    /// Creates or updates the artist for `track`, using the primary artist name for grouping.
    /// - Parameters:
    ///   - artistImageData: Spotify profile photo for the artist, if resolved.
    ///   - useArtistImageOnly: When true (online imports), the artist artwork is
    ///     set ONLY from `artistImageData`; it is never seeded from the track's
    ///     album cover. When false (local imports), album art is the fallback.
    private func updateArtist(for track: Track,
                              artistImageData: Data? = nil,
                              useArtistImageOnly: Bool = false,
                              album: Album? = nil,
                              batch: BucketBatch? = nil) throws {
        let primary = ImportService.primaryArtistName(from: track.artistName)
        // Every credited artist gets their own row and their own copy of the
        // track, so a feature shows up on both artists' pages instead of
        // creating a third artist called "A, B".
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

        // `knownAlbum` is the row `updateAlbum` just resolved for this very
        // track, handed down rather than looked up again: the fetch here was
        // the same predicate, run once per credited artist, materialising an
        // entity that the caller already had in hand.
        let album = try knownAlbum ?? albumRepo.find(title: track.albumTitle, artistName: primary)
        if let album, !artist.albumIDs.contains(album.id) {
            artist.albumIDs.append(album.id)
            modified = true
        }

        // Propagate artwork. The resolved photo belongs to the primary artist and
        // nobody else — handing it to every credit would put the headliner's face
        // on their features' pages. Everyone else gets the album cover as a
        // stand-in (local imports only), which
        // `LibraryService.backfillArtistImages()` swaps for a real photo shortly
        // after the import finishes.
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

    /// One row per distinct album and artist for a whole mix save, instead of
    /// one fetch and one save per track.
    ///
    /// The tail of a mix save used to pay, for every single track: an album
    /// `findOrCreate` fetch, then per credited artist another `findOrCreate`
    /// fetch, an `albumRepo.find` repeating the lookup `updateAlbum` had just
    /// done, and a save. A mix is mostly a handful of artists across a couple
    /// of dozen songs, so nearly all of that was the same few rows fetched,
    /// mutated and committed over and over — 224 ms of main-actor time on a
    /// 24-song save, in chunks big enough to drop frames. Collecting the rows
    /// in memory and committing each one once turns it into a single pass.
    final class BucketBatch {
        var albums:  [String: Album]  = [:]
        var artists: [String: Artist] = [:]
        var dirtyAlbums:  Set<String> = []
        var dirtyArtists: Set<String> = []

        /// `\u{1}` cannot appear in a title or an artist name, so it cannot
        /// collide the way a printable separator could.
        static func albumKey(title: String, artistName: String) -> String {
            "\(title)\u{1}\(artistName)"
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
