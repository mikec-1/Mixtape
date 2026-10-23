// Per-playlist track sort, synced with the account in `user_metadata`
// (see `PlaylistSortSyncService`). Only non-default sorts are stored, keeping
// the map small.

import Foundation
import Combine
import Observation

@Observable
@MainActor
final class PlaylistTrackSortService {

    static let shared = PlaylistTrackSortService()

    /// Playlist id -> sort. Absent means the playlist's own order.
    private(set) var sorts: [UUID: TrackSort] = [:]

    /// Writes the encoded map to `user_metadata`.
    @ObservationIgnored var pushWriter: ((String) -> Void)?

    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    private static let key = "playlist.trackSorts"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key) {
            sorts = Self.decode(raw)
        }
    }

    // MARK: - Reading and writing

    /// Default sort for a playlist. Favourites opens newest-first since its
    /// running order is arbitrary.
    static func defaultSort(for playlistID: UUID) -> TrackSort {
        playlistID == Playlist.favouritesID
            ? TrackSort(field: .dateAdded, ascending: false)
            : TrackSort()
    }

    func sort(for playlistID: UUID) -> TrackSort {
        sorts[playlistID] ?? Self.defaultSort(for: playlistID)
    }

    func setSort(_ sort: TrackSort, for playlistID: UUID) {
        // Compare against this playlist's default, not `isDefault`, or Custom Order
        // on Favourites would never be stored.
        let next: TrackSort? = sort == Self.defaultSort(for: playlistID) ? nil : sort
        guard sorts[playlistID] != next else { return }
        sorts[playlistID] = next
        persist()
        guard !isApplyingRemote else { return }
        schedulePush()
    }

    /// Drops a deleted playlist's sort so the map doesn't grow forever.
    func forget(playlistID: UUID) {
        guard sorts.removeValue(forKey: playlistID) != nil else { return }
        persist()
        schedulePush()
    }

    /// The account's copy wins, same as `PlaylistSortSyncService`.
    func adoptRemote(_ raw: String?) {
        guard let raw else { return }
        // An unpushed local change is newer than the account's copy.
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

    /// Debounces a burst of changes into one write.
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

    /// Flat `id -> "field:direction"` map: readable in the dashboard, and unknown
    /// fields drop out on read.
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
            // Against this playlist's default, not `isDefault` (Favourites defaults to newest-first).
            guard sort != defaultSort(for: id) else { continue }
            result[id] = sort
        }
        return result
    }
}
