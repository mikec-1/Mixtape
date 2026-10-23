// Per-playlist transition style, synced with the account in `user_metadata`, same as
// `PlaylistTrackSortService`. Only overrides are stored; a missing playlist follows Settings.

import Foundation
import Combine
import Observation

@Observable
@MainActor
final class PlaylistTransitionService {

    static let shared = PlaylistTransitionService()

    /// Playlist id -> mode. Absent means the Settings default.
    private(set) var modes: [UUID: CrossfadeMode] = [:]

    /// Writes the encoded map to `user_metadata`.
    @ObservationIgnored var pushWriter: ((String) -> Void)?

    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    private static let key = "playlist.transitions"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key) { modes = Self.decode(raw) }
    }

    /// Nil goes back to the Settings default.
    func setMode(_ mode: CrossfadeMode?, for playlistID: UUID) {
        guard modes[playlistID] != mode else { return }
        modes[playlistID] = mode
        persist()
        guard !isApplyingRemote else { return }
        schedulePush()
    }

    func forget(playlistID: UUID) {
        guard modes.removeValue(forKey: playlistID) != nil else { return }
        persist()
        schedulePush()
    }

    /// The account's copy wins unless a local change is still waiting to push.
    func adoptRemote(_ raw: String?) {
        guard let raw, pushTask == nil else { return }
        let remote = Self.decode(raw)
        guard remote != modes else { return }
        isApplyingRemote = true
        modes = remote
        persist()
        isApplyingRemote = false
    }

    private func persist() {
        UserDefaults.standard.set(Self.encode(modes), forKey: Self.key)
    }

    private func schedulePush() {
        pushTask?.cancel()
        let payload = Self.encode(modes)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pushWriter?(payload)
            self?.pushTask = nil
        }
    }

    /// Flat `id -> "off" | "gapless" | "crossfade"` map, shared with the web.
    static func encode(_ modes: [UUID: CrossfadeMode]) -> String {
        let dict = Dictionary(uniqueKeysWithValues: modes.map { ($0.key.uuidString, $0.value.rawValue) })
        guard let data = try? JSONEncoder().encode(dict) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) -> [UUID: CrossfadeMode] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [UUID: CrossfadeMode] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key), let mode = CrossfadeMode(rawValue: value) { result[id] = mode }
        }
        return result
    }
}
