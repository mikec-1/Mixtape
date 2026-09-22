// SpotlightIndex.swift
// Library songs and artists in system search, with their covers. A song hit
// plays the song; an artist hit opens the artist's Discover page.

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

extension Notification.Name {
    /// Spotlight picked an artist; the root view opens their Discover page.
    /// The name waits in `SpotlightIndex.pendingArtist` for a cold launch.
    static let mixSpotlightArtist = Notification.Name("mix.spotlightArtist")
}

nonisolated enum SpotlightIndex {

    private struct Entry: Sendable {
        let key: String, domain: String, title: String, detail: String
        var artist: String?, album: String?, duration: TimeInterval?
        let ref: ArtworkRef
        var thumbnail: Data?
    }

    private static let artistPrefix = "artist:"
    /// What's in the index, carried across launches so a launch only moves
    /// the difference instead of re-reading every cover. Lost with Caches,
    /// which just means one full rebuild. Bump the name to force one.
    private static let ledger = URL.cachesDirectory.appending(path: "spotlight-index.v2.txt")

    @MainActor private static var indexed: Set<String>?
    @MainActor private static var pass: Task<Void, Never>?
    @MainActor static var pendingArtist: String?

    // MARK: - Indexing

    @MainActor static func update(tracks: [Track], artists: [Artist]) {
        var wanted: [String: Entry] = [:]
        for t in tracks {
            wanted[t.id.uuidString] = Entry(
                key: t.id.uuidString, domain: "songs", title: t.displayTitle,
                detail: [t.displayArtistName, t.albumTitle].filter { !$0.isEmpty }.joined(separator: " — "),
                artist: t.displayArtistName, album: t.albumTitle, duration: t.duration, ref: .track(t.id))
        }
        for a in artists where !a.name.isEmpty {
            let key = artistPrefix + a.name
            wanted[key] = Entry(key: key, domain: "artists", title: a.name, detail: "Artist", ref: .artist(a.id))
        }
        // One pass at a time: each diffs against what the last one finished.
        let previous = pass
        previous?.cancel()
        pass = Task { await previous?.value; await run(wanted) }
    }

    @MainActor private static func run(_ wanted: [String: Entry]) async {
        if indexed == nil,
           let text = try? String(contentsOf: ledger, encoding: .utf8) {
            indexed = Set(text.split(separator: "\n").map(String.init))
        }
        let firstEver = indexed == nil
        var done = indexed ?? []
        let removed = Array(done.subtracting(wanted.keys))
        await remove(removed, clearFirst: firstEver)
        done.subtract(removed)

        let todo = wanted.values.filter { !done.contains($0.key) }
        for start in stride(from: 0, to: todo.count, by: 40) where !Task.isCancelled {
            // Blobs are read on the main actor (the store's models live there),
            // forty at a time with a breather between, and shrunk off it.
            let chunk = todo[start..<min(start + 40, todo.count)].map { entry in
                var e = entry
                e.thumbnail = ArtworkProvider.shared.uncachedData(for: e.ref)
                return e
            }
            await push(chunk)
            done.formUnion(chunk.map(\.key))
            try? await Task.sleep(for: .milliseconds(250))
        }
        indexed = done
        try? done.joined(separator: "\n").write(to: ledger, atomically: true, encoding: .utf8)
    }

    @concurrent private static func remove(_ keys: [String], clearFirst: Bool) async {
        let index = CSSearchableIndex.default()
        if clearFirst { try? await index.deleteSearchableItems(withDomainIdentifiers: ["songs", "artists"]) }
        if !keys.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: keys) }
    }

    @concurrent private static func push(_ entries: [Entry]) async {
        let items = entries.map { e in
            let attributes = CSSearchableItemAttributeSet(contentType: e.domain == "songs" ? .audio : .content)
            attributes.title = e.title
            attributes.contentDescription = e.detail
            attributes.artist = e.artist
            attributes.album = e.album
            attributes.duration = e.duration.map { NSNumber(value: $0) }
            attributes.thumbnailData = e.thumbnail.flatMap {
                ImageDownsampler.downsampledJPEG(from: $0, maxDimension: 160, compressionQuality: 0.7)
            }
            return CSSearchableItem(uniqueIdentifier: e.key, domainIdentifier: e.domain, attributeSet: attributes)
        }
        if !items.isEmpty { try? await CSSearchableIndex.default().indexSearchableItems(items) }
    }

    // MARK: - Opening a hit

    /// Both `RootView.onContinueUserActivity` and the Mac app delegate land
    /// here — macOS only reliably delivers to the delegate — so a second
    /// delivery of the same hit is dropped rather than played twice.
    @MainActor private static var lastOpened: (key: String, at: Date)?

    @MainActor @discardableResult
    static func open(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        if let last = lastOpened, last.key == key, Date().timeIntervalSince(last.at) < 2 { return true }
        lastOpened = (key, Date())

        if key.hasPrefix(artistPrefix) {
            pendingArtist = String(key.dropFirst(artistPrefix.count))
            NotificationCenter.default.post(name: .mixSpotlightArtist, object: nil)
            return true
        }
        guard let id = UUID(uuidString: key), let deps = MixtapeIntents.deps else { return false }
        Task {
            let library = deps.libraryService
            if !library.hasLoaded { await library.loadForDisplay() }
            guard let track = library.track(id: id) else { return }
            await deps.playbackEngine.play(track: track, in: library.tracks,
                                           source: .playlist(id: Playlist.allSongsID, name: "All Songs"))
        }
        return true
    }

    /// The artist a Spotlight hit asked for, once — for the root view to open.
    @MainActor static func takePendingArtist() -> String? {
        defer { pendingArtist = nil }
        return pendingArtist
    }
}
