// A song from online search, not yet in the library. Enough to show a result
// card and build the yt-dlp query.

import Foundation
import CryptoKit

public struct OnlineTrack: Identifiable, Hashable, Sendable, Codable {

    public let id: String          // stable per result (title|artist)
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    /// Deezer track id, used to fetch featured artists.
    public let sourceID: Int?
    public let isExplicit: Bool
    /// Everyone Deezer credits, main artist first. Display only; empty when the
    /// listing doesn't carry contributors.
    public let contributors: [String]

    nonisolated public init(
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

    /// `id` is derived from title and artist, never stored, so a decoded track
    /// always has the same id as one built live.
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
            // Lenient: web rows can carry "" for no artwork.
            artworkURL: (try? box.decodeIfPresent(String.self, forKey: .artworkURL)).flatMap(URL.init(string:)),
            sourceID:   try box.decodeIfPresent(Int.self, forKey: .sourceID),
            isExplicit: try box.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false,
            contributors: try box.decodeIfPresent([String].self, forKey: .contributors) ?? []
        )
    }

    /// Every artist to print: the credited act plus guests. From `contributors`,
    /// falling back to the title for library rows. Display only: `id` hashes
    /// title|artist, so widening the stored credit would change the song's identity.
    public var displayArtists: [String] {
        if contributors.count > 1 { return contributors }
        return ImportService.displayArtists(title: title, artistName: artistName)
    }

    /// The title with guests, e.g. "Ran To Atlanta (feat. Future & Molly Santana)".
    /// Deezer leaves them out. This is what gets stored; `id` stays on the bare title.
    public var displayTitle: String {
        // A title that already names its guests is left exactly as it is.
        guard ImportService.featuredArtists(inTitle: title).isEmpty else { return title }
        let credited = Set(ImportService.creditedArtists(from: artistName).map { $0.lowercased() })
        let guests = displayArtists.filter { !credited.contains($0.lowercased()) }
        guard !guests.isEmpty else { return title }
        return "\(title) (feat. \(ImportService.joinNames(guests)))"
    }

    /// The credit as one comma-separated string, for menus and labels.
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

    /// Deterministic Track.id so repeat plays aggregate in stats.
    public var stableTrackID: UUID { Self.stableID(for: id) }

    /// The identity key for a title and artist. One definition so callers can't
    /// spell it differently.
    public nonisolated static func key(title: String, artistName: String) -> String {
        "\(title.lowercased())|\(artistName.lowercased())"
    }

    /// Every key a stored row might have been minted under, most likely last.
    /// Older rows store the bare title; newer ones store displayTitle.
    public nonisolated static func candidateKeys(title: String, artistName: String) -> [String] {
        var keys = [key(title: title, artistName: artistName)]
        let bare = ImportService.bareTitle(title)
        if bare != title { keys.append(key(title: bare, artistName: artistName)) }
        return keys
    }

    /// The key this row was minted under, proven by matching its SHA-256 id, or nil.
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
    /// Always `.online`; the cache can reclaim the file at any time.
    public func asTrack(artworkData: Data? = nil, localPath: String = "", deviceID: String) -> Track {
        var provenance = FileProvenance.onlinePlaceholder(sourceRef: id)
        provenance.fileHash  = id      // legacy readers still look for the key here
        provenance.localPath = localPath
        return Track(
            id: stableTrackID,
            // The full title (see displayTitle).
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
