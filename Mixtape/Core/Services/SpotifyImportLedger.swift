// SpotifyImportLedger.swift
// Mixtape — Core/Services
//
// Remembers which Spotify playlists, albums and Liked Songs have already been
// brought across, so the picker can say so before someone imports them twice.
//
// The identity question
//   "Is a playlist you've changed still the same playlist?" — for this purpose,
//   yes. Identity is Spotify's id, which is stable across every edit; what
//   changes is how much of it you have. So the ledger stores the id and the
//   track count *at the time of the import*, and the picker turns the pair into
//   the only thing anyone actually wants to know: "you have this already" or
//   "you have this, and there are 12 more songs in it now".
//
// Why it never blocks
//   Importing again is safe — the importer matches on recording, so a re-import
//   adds what's new and reuses the rest. An already-imported row therefore stays
//   tickable; the badge is information, not a gate.
//
// Why it follows the account
//   It used to be a device-local file, on the reasoning that a Spotify
//   connection belongs to a device. That was wrong in practice: importing Liked
//   Songs on the Mac and then opening the picker on the phone offered the whole
//   2263 songs again as if nothing had ever happened, and there is no reading of
//   "you have this already" that is true on one of your devices and false on the
//   other. So the entries ride in `user_metadata` beside the playlist sorts —
//   see `PlaylistTrackSortService` for why that store and not a table.
//
//   The per-entry track ids are the exception: they are tens of kilobytes for a
//   large Liked Songs and there is no room for that in `user_metadata`, so they
//   stay on the device that did the import. Their only job is the exact
//   "+9 −2" after a re-import; a device without them falls back to the count.

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
        /// Where it landed, when that's a single playlist. Absent for albums,
        /// which dissolve into the library rather than becoming a list.
        public var playlistID: UUID?
        /// Spotify's ids for the songs this import saw, when they were carried.
        /// Local-only — stripped from the synced copy, see the file header.
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
        /// Imported, and the source has moved since — songs added, taken away,
        /// or (when only counts are known) whichever way the net went.
        case outdated(at: Date, newSongs: Int, removedSongs: Int)
    }

    /// Keyed by `SpotifyLibraryItem.id` — the kind-qualified id, because
    /// Spotify's ids are only unique within a type.
    @Published public private(set) var entries: [String: Entry] = [:]

    /// Used only to check that what an entry points at still exists. Weak
    /// because the library outlives nothing here and a strong reference back
    /// would be a cycle through `AppDependencies`.
    private weak var libraryService: LibraryService?

    /// The one `AppDependencies` builds. Weak and static only so the auth
    /// service can hand it the account's copy on sign-in the way it does for
    /// the sort services — it is not a singleton, and nothing else uses it.
    public private(set) static weak var shared: SpotifyImportLedger?

    public init(libraryService: LibraryService? = nil) {
        self.libraryService = libraryService
        Self.shared = self
        entries = Self.load()

        // A wiped library hasn't got the songs any more, so claiming they were
        // already imported would talk someone out of the import that would fix
        // it. See `UserDataReset`.
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
        // A playlist the user has since deleted isn't imported any more, and
        // saying it is would talk them out of the import that brings it back.
        // Liked Songs and albums have no single destination to check.
        if let playlistID = entry.playlistID,
           playlistID != Playlist.favouritesID,
           libraryService?.playlist(id: playlistID) == nil {
            return .never
        }
        // Counts, not ids: listing the picker already costs a request per page
        // and fetching every track of every playlist to diff it exactly would
        // be hundreds more against an account that is already rate-limited.
        // So the badge reports the net move, and the exact +new / −removed is
        // reported after the import, which does read every track.
        let delta = item.trackCount - entry.sourceCount
        if delta == 0 { return .imported(at: entry.importedAt) }
        return .outdated(at: entry.importedAt,
                         newSongs: max(delta, 0),
                         removedSongs: max(-delta, 0))
    }

    /// How many songs importing this row would actually bring over: everything
    /// for something never imported, and only what the source has gained for
    /// something that has been. This is what the Import button counts — it used
    /// to add up whole track counts, so re-importing Liked Songs offered to
    /// "Import 2263 Songs" next to a badge reading "9 new".
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

    /// Files a finished import and reports what changed since the last one.
    ///
    /// Exact when both this run and the previous one carried Spotify ids — that
    /// is the only way to see 9 added *and* 2 removed, which the counts alone
    /// net out to 7. Falls back to the count delta otherwise.
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

    /// Drops the record for a source, so the picker offers it as new again.
    ///
    /// Called when the playlist an import created is deleted: keeping the entry
    /// would leave "already imported" standing over something that is gone.
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

    /// Replaces the ledger with the account's own copy when a different user
    /// signs in on this device.
    ///
    /// Nothing is pushed: the entries being dropped belong to the account
    /// signing *out*, and by now the signed-in session is the new one — the
    /// upload would have deleted the incoming user's ledger from their account.
    /// An account with no copy gets an empty one, which is the truth: they have
    /// imported nothing here.
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

    /// Set by `AppDependencies` — writes the encoded ledger into `user_metadata`.
    public var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private var pushTask: Task<Void, Never>?

    /// The account's copy, taken as authoritative on sign-in and on every
    /// session refresh — the same contract `PlaylistTrackSortService` uses.
    ///
    /// Local track ids survive the adoption: they are not in the payload, and
    /// throwing away this device's copy of them would cost the exact diff on
    /// the one device that can still make it.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let remote = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        var merged = remote
        // An import the user undid here is not one this device is missing. The
        // account's copy is authoritative for everything else, but it cannot
        // express a deletion: the entry is simply absent, which reads the same
        // as never having existed. Since this runs on every session refresh, a
        // refresh landing before the debounced push put the badge straight back.
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

    /// Debounced: a multi-item import writes one entry per item and this is one
    /// account update, not one per playlist.
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
