// Albums the user added to the library. `Album` rows are still derived from
// tracks, but only these are listed. Keyed by normalised "title|primary artist".
// Synced in `user_metadata.saved_albums`, like `PlaylistSortSyncService`.

import Foundation
import Combine
import Observation

@Observable
@MainActor
public final class SavedAlbumsService {

    public static let shared = SavedAlbumsService()

    public struct Entry: Codable, Hashable, Sendable {
        public var title: String
        public var artistName: String
        public var savedAt: Date
        /// Songs imported only for this album, hidden from All Songs until saved on their own.
        public var albumOnly: [UUID]? = nil
    }

    /// key -> entry.
    public private(set) var entries: [String: Entry] = [:]

    @ObservationIgnored public var pushWriter: ((String) -> Void)?
    /// Handed the album-only songs of an album being removed, so they leave too.
    @ObservationIgnored public var onUnsave: (([UUID]) -> Void)?

    public var albumOnlyIDs: Set<UUID> { Set(entries.values.flatMap { $0.albumOnly ?? [] }) }

    public func markAlbumOnly(_ id: UUID, title: String, artistName: String) {
        markAlbumOnly([id], title: title, artistName: artistName)
    }

    /// One write per album, since `persist()` re-encodes and pushes everything.
    public func markAlbumOnly(_ ids: [UUID], title: String, artistName: String) {
        let k = Self.key(title: title, artistName: artistName)
        guard var e = entries[k] else { return }
        let existing = Set(e.albumOnly ?? [])
        let added = ids.filter { !existing.contains($0) }
        guard !added.isEmpty else { return }
        e.albumOnly = (e.albumOnly ?? []) + added
        entries[k] = e
        persist()
    }

    /// The song was saved on its own: it's a library song now, not the album's.
    public func promote(_ id: UUID) {
        var changed = false
        for (k, var e) in entries where e.albumOnly?.contains(id) == true {
            e.albumOnly?.removeAll { $0 == id }
            entries[k] = e
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        let raw = Self.encode(entries)
        UserDefaults.standard.set(raw, forKey: Self.key)
        pushWriter?(raw)
    }

    private static let key = "library.savedAlbums"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key) { entries = Self.decode(raw) }
    }

    public static func key(title: String, artistName: String) -> String {
        let pair = KeyPair(title: title, artistName: artistName)
        if let hit = keys[pair] { return hit }
        let artist = ImportService.creditedArtists(from: artistName).first ?? artistName
        let key = (title + "|" + artist).lowercased().trimmingCharacters(in: .whitespaces)
        if keys.count > 20_000 { keys.removeAll() }
        keys[pair] = key
        return key
    }

    /// Album lists sort by `savedAt`, so every comparison built two keys.
    private struct KeyPair: Hashable { let title: String; let artistName: String }
    private static var keys: [KeyPair: String] = [:]

    public func isSaved(title: String, artistName: String) -> Bool {
        entries[Self.key(title: title, artistName: artistName)] != nil
    }

    public func isSaved(_ album: Album) -> Bool { isSaved(title: album.title, artistName: album.artistName) }

    public func savedAt(_ album: Album) -> Date? { entries[Self.key(title: album.title, artistName: album.artistName)]?.savedAt }

    public func setSaved(_ saved: Bool, title: String, artistName: String) {
        let k = Self.key(title: title, artistName: artistName)
        let orphans = saved ? [] : (entries[k]?.albumOnly ?? [])
        entries[k] = saved ? Entry(title: title, artistName: artistName, savedAt: Date()) : nil
        persist()
        // Only the user unsaves (remote changes come through `adoptRemote`), so a big album's songs may go.
        if !orphans.isEmpty { SupabaseSyncService.allowBulk("unsave-album"); onUnsave?(orphans) }
    }

    public func adoptRemote(_ raw: String?) {
        guard let raw else { return }
        let remote = Self.decode(raw)
        guard remote != entries else { return }
        entries = remote
        UserDefaults.standard.set(raw, forKey: Self.key)
    }

    static func encode(_ e: [String: Entry]) -> String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        return (try? enc.encode(e)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(_ raw: String) -> [String: Entry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([String: Entry].self, from: Data(raw.utf8))) ?? [:]
    }
}
