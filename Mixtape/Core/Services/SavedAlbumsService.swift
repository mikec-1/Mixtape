// SavedAlbumsService.swift
// Mixtape — Core/Services
//
// Which albums the user added to their library, Spotify-style. Adding a song no
// longer implies its album: `Album` rows are still derived from tracks (they
// back album pages and artwork), but only the albums named here are listed in
// the Library. Keyed by normalised "title|primary artist" so a Discover album
// and the local row built from its songs are the same entry.
//
// Synced in `user_metadata.saved_albums`, same shape as `PlaylistSortSyncService`.

import Foundation
import Combine

@MainActor
public final class SavedAlbumsService: ObservableObject {

    public static let shared = SavedAlbumsService()

    public struct Entry: Codable, Hashable, Sendable {
        public var title: String
        public var artistName: String
        public var savedAt: Date
        /// Songs imported only because this album was added — kept out of All
        /// Songs until the user saves one on its own.
        public var albumOnly: [UUID]? = nil
    }

    /// key → entry.
    @Published public private(set) var entries: [String: Entry] = [:]

    public var pushWriter: ((String) -> Void)?
    /// Handed the album-only songs of an album being removed, so they leave too.
    public var onUnsave: (([UUID]) -> Void)?

    public var albumOnlyIDs: Set<UUID> { Set(entries.values.flatMap { $0.albumOnly ?? [] }) }

    public func markAlbumOnly(_ id: UUID, title: String, artistName: String) {
        markAlbumOnly([id], title: title, artistName: artistName)
    }

    /// One write for a whole record, because `persist()` re-encodes every entry
    /// and pushes it — a fifty-album import doing that once per song is the
    /// same freeze the batched playlist writes exist to avoid.
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
        let artist = ImportService.creditedArtists(from: artistName).first ?? artistName
        return (title + "|" + artist).lowercased().trimmingCharacters(in: .whitespaces)
    }

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
        if !orphans.isEmpty { onUnsave?(orphans) }
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
