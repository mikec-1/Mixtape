// OnlineTrack.swift
// Mixtape
//
// A song found via online search but not yet in the library — just enough to
// show a result card and build the yt-dlp query.

import Foundation
import CryptoKit

public struct OnlineTrack: Identifiable, Hashable, Sendable {

    public let id: String          // stable per result (title|artist)
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    /// Deezer track id, when known — used to fetch featured artists.
    public let sourceID: Int?
    public let isExplicit: Bool

    public init(
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval = 0,
        artworkURL: URL? = nil,
        sourceID: Int? = nil,
        isExplicit: Bool = false
    ) {
        self.id         = "\(title.lowercased())|\(artistName.lowercased())"
        self.title      = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration   = duration
        self.artworkURL = artworkURL
        self.sourceID   = sourceID
        self.isExplicit = isExplicit
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
    public static func stableID(for key: String) -> UUID {
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
    public func asTrack(artworkData: Data? = nil, localPath: String = "", deviceID: String) -> Track {
        Track(
            id: stableTrackID,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkData: artworkData,
            sync: SyncMetadata(deviceID: deviceID),
            file: FileProvenance(fileHash: id, fileSize: 0, localPath: localPath)
        )
    }
}
