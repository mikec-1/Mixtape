// Which Spotify playlists, albums and Liked Songs were already imported, so
// the picker can badge them. Identity is Spotify's id; the stored track count
// shows "12 more songs now". Never blocks: re-import is safe and only adds
// what's new.
// Entries sync via `user_metadata`. Per-entry track ids stay on device (too big)
// and only give the exact "+9 −2"; other devices fall back to counts.

import Foundation
import Combine

@MainActor
public final class SpotifyImportLedger: ObservableObject {

    // MARK: - Entry

    public struct Entry: Codable, Sendable, Hashable {
        /// What it was called on Spotify when it was imported.
        public var name: String
        public var importedAt: Date
        /// Spotify's track count at the time, for "12 new songs since".
        public var sourceCount: Int
        /// Destination playlist. Nil for albums.
        public var playlistID: UUID?
        /// Spotify track ids from this import. Local-only.
        public var sourceTrackIDs: [String]?
    }

    /// What one re-import actually changed at the source since last time.
    public struct Change: Sendable, Equatable {
        public var new = 0
        public var removed = 0
        public var isEmpty: Bool { new == 0 && removed == 0 }
    }

    /// What the picker shows for one row.
    public enum State: Equatable {
        case never
        /// Imported, and Spotify's count hasn't grown since.
        case imported(at: Date)
        /// Imported, but the source changed since.
        case outdated(at: Date, newSongs: Int, removedSongs: Int)
    }

    /// Keyed by the kind-qualified `SpotifyLibraryItem.id`.
    @Published public private(set) var entries: [String: Entry] = [:]

    /// Checks entries still point at something. Weak to avoid a cycle.
    private weak var libraryService: LibraryService?

    /// Set by `AppDependencies` so auth can hand over the account's copy. Not a singleton.
    public private(set) static weak var shared: SpotifyImportLedger?

    public init(libraryService: LibraryService? = nil) {
        self.libraryService = libraryService
        Self.shared = self
        entries = Self.load()

        // After a wipe, "already imported" would be false.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let reset = UserDataReset.from(note)
                guard reset.clearedLibrary, !reset.isAccountSwitch else { return }
                self?.forgetAll()
            }
        }
    }

    // MARK: - Reading

    public func state(for item: SpotifyLibraryItem) -> State {
        guard let entry = entries[item.id] else { return .never }
        // Deleted playlists aren't imported any more.
        if let playlistID = entry.playlistID,
           playlistID != Playlist.favouritesID,
           libraryService?.playlist(id: playlistID) == nil {
            return .never
        }
        // Counts only; diffing every playlist's tracks costs too many requests. The
        // exact diff is reported after import.
        let delta = item.trackCount - entry.sourceCount
        if delta == 0 { return .imported(at: entry.importedAt) }
        return .outdated(at: entry.importedAt,
                         newSongs: max(delta, 0),
                         removedSongs: max(-delta, 0))
    }

    /// Songs an import would bring: everything if never imported, else only the gain.
    public func newSongCount(for item: SpotifyLibraryItem) -> Int {
        switch state(for: item) {
        case .never:                        return item.trackCount
        case .imported:                     return 0
        case .outdated(_, let new, _):      return new
        }
    }

    public func hasImported(_ item: SpotifyLibraryItem) -> Bool {
        state(for: item) != .never
    }

    public func entry(for item: SpotifyLibraryItem) -> Entry? { entries[item.id] }

    // MARK: - Writing

    /// Records a finished import and reports what changed. Exact when both runs
    /// carried Spotify ids, otherwise a count delta.
    @discardableResult
    public func record(_ item: SpotifyLibraryItem,
                       playlistID: UUID?,
                       sourceTrackIDs: [String]? = nil) -> Change {
        let previous = entries[item.id]
        var change = Change()
        if let before = previous?.sourceTrackIDs, let after = sourceTrackIDs {
            let old = Set(before), now = Set(after)
            change.new     = now.subtracting(old).count
            change.removed = old.subtracting(now).count
        } else if let before = previous {
            let delta = item.trackCount - before.sourceCount
            change.new     = max(delta, 0)
            change.removed = max(-delta, 0)
        } else {
            change.new = item.trackCount
        }

        entries[item.id] = Entry(
            name:           item.name,
            importedAt:     .now,
            sourceCount:    item.trackCount,
            playlistID:     playlistID,
            // Never drop ids we already had for a run that couldn't supply any.
            sourceTrackIDs: sourceTrackIDs ?? previous?.sourceTrackIDs
        )
        forgotten.remove(item.id)
        save()
        return change
    }

    /// Forgets a source so the picker offers it as new. Called when its playlist is deleted.
    public func forget(playlistID: UUID) {
        let stale = entries.filter { $0.value.playlistID == playlistID }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { entries[key] = nil }
        forgotten.formUnion(stale)
        save()
    }

    public func forgetAll() {
        guard !entries.isEmpty else { return }
        forgotten.formUnion(entries.keys)
        entries.removeAll()
        save()
    }

    /// Swaps in the new account's ledger. Not pushed, or it would overwrite the
    /// incoming user's copy.
    public func accountDidChange(remote raw: String?) {
        isApplyingRemote = true
        entries = [:]
        forgotten.removeAll()
        save()
        isApplyingRemote = false
        adoptRemote(raw)
    }

    // MARK: - Persistence

    private static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        let dir = base.appendingPathComponent("Mixtape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spotify-imports.json")
    }()

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.url, options: .atomic)
        guard !isApplyingRemote else { return }
        schedulePush()
    }

    // MARK: - Account sync

    /// Writes the encoded ledger to `user_metadata`.
    public var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private var pushTask: Task<Void, Never>?

    /// Adopts the account's copy on sign-in and refresh. Local track ids survive.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let remote = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        var merged = remote
        // Keep local deletions: the remote copy can't express them, and a refresh
        // before the push would bring the badge back.
        var stale = false
        for key in forgotten where merged[key] != nil {
            merged[key] = nil
            stale = true
        }
        for (key, var entry) in merged where entry.sourceTrackIDs == nil {
            entry.sourceTrackIDs = entries[key]?.sourceTrackIDs
            merged[key] = entry
        }
        if merged != entries {
            isApplyingRemote = true
            entries = merged
            save()
            isApplyingRemote = false
        }
        // The account still lists what this device dropped, so say it again.
        if stale { schedulePush() }
    }

    /// Imports the user undid on this device. See `adoptRemote`.
    private var forgotten: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "mix.spotifyForgottenImports") ?? []
    ) {
        didSet { UserDefaults.standard.set(Array(forgotten), forKey: "mix.spotifyForgottenImports") }
    }

    /// Debounced: one account write per import.
    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            var stripped = entries
            for (key, var entry) in stripped {
                entry.sourceTrackIDs = nil
                stripped[key] = entry
            }
            guard let data = try? JSONEncoder().encode(stripped),
                  let raw  = String(data: data, encoding: .utf8)
            else { return }
            pushWriter?(raw)
        }
    }
}
