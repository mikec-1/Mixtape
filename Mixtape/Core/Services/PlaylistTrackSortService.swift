// PlaylistTrackSortService.swift
// Mixtape — Core/Services
//
// Remembers how each individual playlist is sorted — "Playlist Order",
// "Date Added", "Title" and the direction — and carries that with the account
// rather than the device.
//
// A sort used to last exactly as long as the visit: `PlaylistDetailView` held
// it in `@State` and reset it on the way out. That is right for a filter and
// wrong for a sort. Someone who reads one playlist newest-first is going to
// want it newest-first tomorrow, and having to say so on every visit — and
// again on the other device — is the app forgetting something it watched the
// user decide.
//
// Only *non-default* sorts are stored. A playlist left in its own running
// order writes nothing and drops any entry it had, so the map stays a handful
// of rows even in a library of hundreds of playlists — which matters, because
// it rides in `user_metadata` beside the library sort order. See
// [PlaylistSortSyncService] for why that store and not a table.

import Foundation
import Combine

@MainActor
final class PlaylistTrackSortService: ObservableObject {

    static let shared = PlaylistTrackSortService()

    /// Playlist id → the sort chosen for it. Absent means "the playlist's own
    /// order", which is also what a reset writes.
    @Published private(set) var sorts: [UUID: TrackSort] = [:]

    /// Set by `AppDependencies` — writes the encoded map into `user_metadata`.
    var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private var pushTask: Task<Void, Never>?
    private static let key = "playlist.trackSorts"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key) {
            sorts = Self.decode(raw)
        }
    }

    // MARK: - Reading and writing

    /// What a playlist opens in when nothing has been chosen for it.
    ///
    /// Favourites is the exception: it is not a sequenced playlist, it is a
    /// running log of what you saved, so it opens newest-first the way Liked
    /// Songs does in Spotify. Its running order is *not* chronological — songs
    /// arrive there from a Spotify pull, a heart press and a sync in whatever
    /// order those happen — so "Custom Order" there was an order nobody chose,
    /// and songs saved an hour ago landed in the middle of the list.
    static func defaultSort(for playlistID: UUID) -> TrackSort {
        playlistID == Playlist.favouritesID
            ? TrackSort(field: .dateAdded, ascending: false)
            : TrackSort()
    }

    func sort(for playlistID: UUID) -> TrackSort {
        sorts[playlistID] ?? Self.defaultSort(for: playlistID)
    }

    func setSort(_ sort: TrackSort, for playlistID: UUID) {
        // Compared against *this* playlist's default rather than `isDefault`, or
        // choosing Custom Order on Favourites would store nothing and fall
        // straight back to newest-first.
        let next: TrackSort? = sort == Self.defaultSort(for: playlistID) ? nil : sort
        guard sorts[playlistID] != next else { return }
        sorts[playlistID] = next
        persist()
        guard !isApplyingRemote else { return }
        schedulePush()
    }

    /// Drops a playlist's remembered sort — for when the playlist itself goes.
    /// A map that keeps naming deleted playlists is one that only ever grows.
    func forget(playlistID: UUID) {
        guard sorts.removeValue(forKey: playlistID) != nil else { return }
        persist()
        schedulePush()
    }

    /// Takes the account's copy as authoritative, on sign-in and on every
    /// session refresh — the same contract as `PlaylistSortSyncService`.
    func adoptRemote(_ raw: String?) {
        guard let raw else { return }
        // A change made in the last second hasn't been pushed yet, so the
        // account's copy is behind us and adopting it would undo the choice the
        // user just made.
        guard pushTask == nil else { return }
        let remote = Self.decode(raw)
        guard remote != sorts else { return }
        isApplyingRemote = true
        sorts = remote
        persist()
        isApplyingRemote = false
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(Self.encode(sorts), forKey: Self.key)
    }

    /// Coalesces a burst of changes into one write. Flipping through four
    /// fields to find the one you meant is a single decision, not four, and
    /// each push costs an auth round trip and a `.userUpdated` event.
    private func schedulePush() {
        pushTask?.cancel()
        let payload = Self.encode(sorts)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pushWriter?(payload)
            self?.pushTask = nil
        }
    }

    // MARK: - Coding

    /// A flat `[String: String]` of `id → "field:direction"`, so the value
    /// stays readable in the Supabase dashboard and survives a new sort field
    /// being added later (an unknown field simply drops out on read).
    static func encode(_ sorts: [UUID: TrackSort]) -> String {
        let pairs = sorts.map { ($0.key.uuidString, "\($0.value.field.rawValue):\($0.value.ascending ? "asc" : "desc")") }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        guard let data = try? JSONEncoder().encode(dict) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) -> [UUID: TrackSort] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }

        var result: [UUID: TrackSort] = [:]
        for (key, value) in dict {
            guard let id = UUID(uuidString: key) else { continue }
            let parts = value.split(separator: ":")
            guard let fieldRaw = parts.first,
                  let field = TrackSortField(rawValue: String(fieldRaw))
            else { continue }
            let sort = TrackSort(field: field, ascending: parts.last != "desc")
            // Against *this* playlist's default, not `isDefault`. Favourites
            // defaults to newest-first, so "Playlist Order" there is a real
            // choice — dropping it on read is what made that one playlist snap
            // back to Date Added on every session refresh.
            guard sort != defaultSort(for: id) else { continue }
            result[id] = sort
        }
        return result
    }
}
