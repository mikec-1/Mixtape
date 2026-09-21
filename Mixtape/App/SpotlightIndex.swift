// SpotlightIndex.swift
// Library songs in system search. A hit plays the song — see RootView's
// `onContinueUserActivity(CSSearchableItemActionType)`.

import CoreSpotlight
import UniformTypeIdentifiers

nonisolated enum SpotlightIndex {

    private struct Song: Sendable {
        let id: UUID, title: String, artist: String, album: String, duration: TimeInterval
    }

    /// What this launch has indexed; nil until the first pass. The index
    /// outlives the app — and the account — so the first pass starts clean,
    /// and after that only the difference moves. Ids are content hashes, so an
    /// edited title is a remove plus an add, not a stale entry.
    @MainActor private static var indexed: Set<UUID>?

    @MainActor static func update(_ tracks: [Track]) {
        let old = indexed ?? []
        let ids = Set(tracks.map(\.id))
        let added = tracks.filter { !old.contains($0.id) }.map {
            Song(id: $0.id, title: $0.displayTitle, artist: $0.displayArtistName,
                 album: $0.albumTitle, duration: $0.duration)
        }
        let removed = old.subtracting(ids).map(\.uuidString)
        let clearFirst = indexed == nil
        indexed = ids
        Task { await push(added, removed: removed, clearFirst: clearFirst) }
    }

    // ponytail: passes aren't serialised; the 5 s debounce upstream keeps them apart.
    @concurrent private static func push(_ songs: [Song], removed: [String], clearFirst: Bool) async {
        let index = CSSearchableIndex.default()
        if clearFirst { try? await index.deleteSearchableItems(withDomainIdentifiers: ["songs"]) }
        if !removed.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: removed) }
        let items = songs.map { song in
            let attributes = CSSearchableItemAttributeSet(contentType: .audio)
            attributes.title = song.title
            attributes.artist = song.artist
            attributes.album = song.album
            attributes.contentDescription = [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " — ")
            attributes.duration = NSNumber(value: song.duration)
            return CSSearchableItem(uniqueIdentifier: song.id.uuidString, domainIdentifier: "songs", attributeSet: attributes)
        }
        if !items.isEmpty { try? await index.indexSearchableItems(items) }
    }
}
