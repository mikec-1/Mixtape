// OnlineTrack.swift
// Mixtape
//
// A song found via online search but not yet in the library — just enough to
// show a result card and build the yt-dlp query.

import Foundation
import CryptoKit

public struct OnlineTrack: Identifiable, Hashable, Sendable, Codable {

    public let id: String          // stable per result (title|artist)
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    /// Deezer track id, when known — used to fetch featured artists.
    public let sourceID: Int?
    public let isExplicit: Bool
    /// Everyone Deezer credits on the track — main artist first, guests after.
    /// Display only (see `displayArtistName`), empty when the source listing
    /// doesn't carry contributors.
    public let contributors: [String]

    public init(
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval = 0,
        artworkURL: URL? = nil,
        sourceID: Int? = nil,
        isExplicit: Bool = false,
        contributors: [String] = []
    ) {
        self.id         = Self.key(title: title, artistName: artistName)
        self.title      = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration   = duration
        self.artworkURL = artworkURL
        self.sourceID   = sourceID
        self.isExplicit = isExplicit
        self.contributors = contributors
    }

    // MARK: - Codable

    /// `id` is derived from the title and artist, never stored: writing it out
    /// and reading it back would let a decoded track disagree with the one the
    /// same metadata builds live, which is the one thing an id used for dedup
    /// and for `stableTrackID` must never do.
    private enum CodingKeys: String, CodingKey {
        case title, artistName, albumTitle, duration, artworkURL, sourceID, isExplicit, contributors
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title:      try box.decode(String.self, forKey: .title),
            artistName: try box.decode(String.self, forKey: .artistName),
            albumTitle: try box.decode(String.self, forKey: .albumTitle),
            duration:   try box.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            artworkURL: try box.decodeIfPresent(URL.self, forKey: .artworkURL),
            sourceID:   try box.decodeIfPresent(Int.self, forKey: .sourceID),
            isExplicit: try box.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false,
            contributors: try box.decodeIfPresent([String].self, forKey: .contributors) ?? []
        )
    }

    /// Every artist to *print* for this song, one entry per name: the credited
    /// act, plus every guest.
    ///
    /// Deezer credits one artist per track and keeps the guests in
    /// `contributors` — the track detail for "Ran To Atlanta" is a bare title
    /// and a three-name contributor list, so there is nothing to read out of
    /// the title. Library rows have only the title to go on, which is why that
    /// stays as the fallback. Either way a Discover row now says what the
    /// library says instead of a bare "Drake".
    ///
    /// Display only, and it has to stay that way: `id` is "title|artist" and
    /// `stableTrackID` hashes it, so widening the stored credit would give the
    /// song a different identity — a second library row, split play counts, and
    /// a cache miss on a file already downloaded.
    public var displayArtists: [String] {
        if contributors.count > 1 { return contributors }
        return ImportService.displayArtists(title: title, artistName: artistName)
    }

    /// What the song is *called*, guests included.
    ///
    /// Deezer files the guests in `contributors` and leaves them out of the
    /// title — "Ran To Atlanta", where the song is published everywhere else as
    /// "Ran To Atlanta (feat. Future & Molly Santana)". Printing the bare title
    /// isn't a neutral choice: it silently renames the record.
    ///
    /// So the credit goes back on, and the reconstructed title is what gets
    /// stored on the library row too. `id` stays built from the bare title, so
    /// identity — and with it `stableTrackID`, the cache key and every playlist
    /// that already points at this song — is untouched by any of this.
    public var displayTitle: String {
        // A title that already names its guests is left exactly as it is.
        guard ImportService.featuredArtists(inTitle: title).isEmpty else { return title }
        let credited = Set(ImportService.creditedArtists(from: artistName).map { $0.lowercased() })
        let guests = displayArtists.filter { !credited.contains($0.lowercased()) }
        guard !guests.isEmpty else { return title }
        return "\(title) (feat. \(ImportService.joinNames(guests)))"
    }

    /// The same credit as one comma-separated string, for the places that can't
    /// lay out a name per link (menus, accessibility labels, subtitles).
    public var displayArtistName: String {
        displayArtists.joined(separator: ", ")
    }

    public var searchQuery: String {
        "\(artistName) \(title)".trimmingCharacters(in: .whitespaces)
    }

    /// Filesystem-safe stem for the cache file.
    public var cacheStem: String {
        let allowed = CharacterSet.alphanumerics
        let scrubbed = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scrubbed).prefix(80).description
    }

    /// Deterministic Track.id so repeat plays of the same song aggregate in stats
    /// instead of each looking like a brand-new track.
    public var stableTrackID: UUID { Self.stableID(for: id) }

    /// SHA-256 the key and fold the first 16 bytes into a UUID. Same key → same UUID.
    /// The identity key for a title and artist. One definition, because the
    /// whole class of bug this file has seen is two places spelling it apart.
    public nonisolated static func key(title: String, artistName: String) -> String {
        "\(title.lowercased())|\(artistName.lowercased())"
    }

    /// Every key a stored row *might* have been minted under, most-likely last.
    ///
    /// Two, not one, because the stored title and the identity can legitimately
    /// disagree: `asTrack` writes `displayTitle` — the title with its feature
    /// credit printed back on — into the row, while the key stays on the source's
    /// bare title. A row saved before that change has the bare title stored and
    /// matches the first candidate; a row saved after it matches the second.
    public nonisolated static func candidateKeys(title: String, artistName: String) -> [String] {
        var keys = [key(title: title, artistName: artistName)]
        let bare = ImportService.bareTitle(title)
        if bare != title { keys.append(key(title: bare, artistName: artistName)) }
        return keys
    }

    /// The key this row was actually minted under, proven by the hash, or nil.
    ///
    /// The proof is the point: `stableID` is a SHA-256, so a candidate that
    /// lands on the row's own id cannot have done so by coincidence. Callers use
    /// this instead of recomputing a single key and hoping, which is what made a
    /// feature-credited song read as "shared from another library".
    public nonisolated static func identityKey(title: String, artistName: String, matching id: UUID) -> String? {
        candidateKeys(title: title, artistName: artistName).first { stableID(for: $0) == id }
    }

    public nonisolated static func stableID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        // version 5 / variant bits for a well-formed UUID
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: t)
    }

    /// A provisional Track for display. Pass `localPath` when a cached file exists.
    ///
    /// The row is always `.online`: a cached file behind it is a convenience the
    /// cache may reclaim at any time, not a change in what the song *is*.
    public func asTrack(artworkData: Data? = nil, localPath: String = "", deviceID: String) -> Track {
        var provenance = FileProvenance.onlinePlaceholder(sourceRef: id)
        provenance.fileHash  = id      // legacy readers still look for the key here
        provenance.localPath = localPath
        return Track(
            id: stableTrackID,
            // The full title, not the source's bare one — see `displayTitle`.
            title: displayTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkData: artworkData,
            isExplicit: isExplicit,
            sync: SyncMetadata(deviceID: deviceID),
            file: provenance
        )
    }
}
