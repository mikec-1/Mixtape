// SpotifyLibraryPickerModel.swift
// Mixtape — Features/Import
//
// The listing-and-migrating half of the Spotify library import, with no opinion
// about where it's drawn.
//
// It used to live inside `SpotifyLibraryPickerView`, which was fine while a
// sheet was the only way to reach it. There are now two hosts — that sheet, and
// the Spotify connection in Settings, which shows the same flow inline in the
// main window — and a flow that writes to someone's library is not a thing to
// own two copies of.

import SwiftUI
import Combine

@MainActor
public final class SpotifyLibraryPickerModel: ObservableObject {

    public enum Phase: Equatable {
        /// Not connected, or connected and not yet asked.
        case idle
        case loading
        case choosing
        case migrating
        case finished
        case failed(String)
    }

    @Published public var phase: Phase = .idle
    @Published public var items: [SpotifyLibraryItem] = []
    @Published public var selection: Set<String> = []
    @Published public var filter = ""
    /// Parts of the library that failed to load, in words. Never empty and
    /// ignored: an absent section is otherwise identical to an empty one.
    @Published public private(set) var warnings: [String] = []
    @Published public var isConnecting = false

    /// Keep what's imported in step with Spotify afterwards.
    ///
    /// Off by default: an import is a one-off unless someone says otherwise,
    /// and a mirror takes the playlist's editing away in exchange.
    @Published public var keepInSync = false

    @Published public var progress: SpotifyImportService.MigrationProgress?
    @Published public var result: SpotifyImportService.MigrationResult?

    private let spotifyClient: SpotifyClient
    private let importService: SpotifyImportService
    private let auth: SpotifyAuth
    /// Absent only in previews and tests; without it the "keep in sync" toggle
    /// has nothing to write to, so it isn't offered.
    private let followService: SpotifyFollowService?

    /// Guards against two listings running at once: a host loads as soon as
    /// `connect()` succeeds *and* re-fires the moment `isAuthorized` flips.
    /// Both are right, and without this they'd both fetch.
    private var isLoading = false
    private var migration: Task<Void, Never>?

    /// Absent only in previews and tests; without it no row can say whether it
    /// has been imported before, which is a missing badge and nothing worse.
    public let ledger: SpotifyImportLedger?

    public init(spotifyClient: SpotifyClient,
                importService: SpotifyImportService,
                auth: SpotifyAuth,
                followService: SpotifyFollowService? = nil,
                ledger: SpotifyImportLedger? = nil) {
        self.spotifyClient = spotifyClient
        self.importService = importService
        self.auth = auth
        self.followService = followService
        self.ledger = ledger
    }

    // MARK: - Already imported

    public func importState(for item: SpotifyLibraryItem) -> SpotifyImportLedger.State {
        ledger?.state(for: item) ?? .never
    }

    /// Selected rows that have been through an import before. Drives the note
    /// under the list — the reason someone might want to reconsider a tick.
    public var selectedAlreadyImported: [SpotifyLibraryItem] {
        guard let ledger else { return [] }
        return items.filter { selection.contains($0.id) && ledger.hasImported($0) }
    }

    /// Whether to show the "keep in sync" toggle at all.
    ///
    /// Albums are left out on purpose: an imported album is a set of songs in
    /// the library, not a playlist with an owner, so there'd be nothing for a
    /// mirror to keep in step.
    public var canFollow: Bool {
        followService != nil
            && items.contains { selection.contains($0.id) && $0.kind != .album }
    }

    // MARK: - Derived

    /// Named `Picker…` rather than `Section` because SwiftUI already owns that
    /// name, and the lists built from these make real `Section`s out of them.
    public struct PickerSection {
        public let title: String
        public let items: [SpotifyLibraryItem]
    }

    /// Grouped by kind and filtered, in the order someone thinks about them:
    /// their saved songs, then their playlists, then their albums.
    public var visibleSections: [PickerSection] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? items : items.filter {
            $0.name.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
        return [
            PickerSection(title: "Saved Songs", items: matching.filter { $0.kind == .likedSongs }),
            PickerSection(title: "Playlists",   items: matching.filter { $0.kind == .playlist }),
            PickerSection(title: "Albums",      items: matching.filter { $0.kind == .album }),
        ].filter { !$0.items.isEmpty }
    }

    public var selectedSongCount: Int {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.trackCount }
    }

    /// What the button offers to import: whole track counts for things never
    /// imported, and only the new songs for things already brought over. The
    /// button used to add up `trackCount` regardless, so a row badged "9 new"
    /// sat under a button offering to "Import 2263 Songs".
    public var selectedNewSongCount: Int {
        guard let ledger else { return selectedSongCount }
        return items.filter { selection.contains($0.id) }
            .reduce(0) { $0 + ledger.newSongCount(for: $1) }
    }

    /// What the last run actually changed at the source, summed over its items.
    @Published public private(set) var lastChange = SpotifyImportLedger.Change()

    public func toggle(_ item: SpotifyLibraryItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else                           { selection.insert(item.id) }
    }

    public func toggleAllVisible() {
        let visible = visibleSections.flatMap(\.items)
        guard !visible.isEmpty else { return }
        if visible.allSatisfy({ selection.contains($0.id) }) {
            for item in visible { selection.remove(item.id) }
            return
        }
        // "All" means all the ones there's a point importing. Someone with
        // forty playlists and thirty-eight already across wants the two new
        // ones; a second tap takes the rest if they really did mean everything.
        let fresh = visible.filter { !(ledger?.hasImported($0) ?? false) }
        let target = fresh.isEmpty || fresh.allSatisfy { selection.contains($0.id) }
            ? visible
            : fresh
        for item in target { selection.insert(item.id) }
    }

    public var allVisibleSelected: Bool {
        let visible = visibleSections.flatMap(\.items)
        return !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
    }

    // MARK: - Actions

    public func connect() {
        isConnecting = true
        Task {
            do {
                try await auth.connect()
                await load()
            } catch let error as SpotifyAuthError {
                phase = .failed(error.errorDescription ?? "Couldn't connect to Spotify.")
            } catch {
                phase = .failed("Couldn't connect to Spotify. Please try again.")
            }
            isConnecting = false
        }
    }

    public func loadIfNeeded() async {
        guard auth.isAuthorized, phase == .idle else { return }
        await load()
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        phase = .loading
        do {
            let token = try await auth.validAccessToken()
            let fetched = try await spotifyClient.fetchLibrary(accessToken: token)
            items   = fetched.items
            // Shown above the list rather than instead of it: the playlists that
            // did load are still worth picking from.
            warnings = fetched.missing.map(\.sentence)
            // Nothing pre-ticked: this writes to someone's library, and the
            // difference between "everything" and "these four" should be a
            // decision they made rather than one they failed to undo.
            selection = []
            phase = .choosing
        } catch let error as SpotifyAuthError {
            phase = .failed(error.errorDescription ?? "Couldn't read your Spotify library.")
        } catch let error as SpotifyPlaylistError {
            phase = .failed(error.errorDescription ?? "Couldn't read your Spotify library.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func startMigration() {
        let chosen = items.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }

        phase = .migrating
        progress = nil
        result = nil

        migration = Task {
            do {
                let token = try await auth.validAccessToken()
                let outcome = await importService.migrate(chosen,
                                                          using: spotifyClient,
                                                          accessToken: token) { update in
                    self.progress = update
                }
                result = outcome
                if keepInSync { follow(chosen, outcome: outcome) }
                recordImports(chosen, outcome: outcome)
                phase = .finished
            } catch let error as SpotifyAuthError {
                phase = .failed(error.errorDescription ?? "Import failed.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
            migration = nil
        }
    }

    /// Turns a finished import into standing links.
    ///
    /// Only what actually landed: `destinations` is written as each item
    /// succeeds, so a playlist that failed mid-run is simply absent here and
    /// never becomes a mirror of something that isn't there.
    private func follow(_ chosen: [SpotifyLibraryItem],
                        outcome: SpotifyImportService.MigrationResult) {
        guard let followService else { return }
        for item in chosen {
            guard let playlistID = outcome.destinations[item.id] else { continue }
            let kind: SpotifyFollowService.Link.Kind
            switch item.kind {
            case .playlist:   kind = .playlist
            case .likedSongs: kind = .likedSongs
            case .album:      continue
            }
            followService.link(
                .init(sourceID: item.sourceID, kind: kind, name: item.name,
                      lastSyncedAt: .now),
                toPlaylist: playlistID
            )
        }
    }

    /// Writes what landed into the ledger, so the picker can say "already
    /// imported" next time.
    ///
    /// Driven by `completedItemIDs` rather than by what was chosen: a run that
    /// was stopped is rolled back, and an item that failed never arrived, so
    /// neither should leave a record claiming otherwise.
    private func recordImports(_ chosen: [SpotifyLibraryItem],
                               outcome: SpotifyImportService.MigrationResult) {
        guard let ledger else { return }
        let done = Set(outcome.completedItemIDs)
        var total = SpotifyImportLedger.Change()
        for item in chosen where done.contains(item.id) {
            let change = ledger.record(item,
                                       playlistID: outcome.destinations[item.id],
                                       sourceTrackIDs: outcome.sourceTrackIDs[item.id])
            total.new     += change.new
            total.removed += change.removed
        }
        lastChange = total
    }

    public func cancelMigration() {
        migration?.cancel()
    }

    /// Back to the chooser after a run, without re-reading the account — the
    /// listing is still accurate and re-fetching it would drop the scroll.
    public func startOver() {
        result = nil
        progress = nil
        selection = []
        phase = items.isEmpty ? .idle : .choosing
    }
}
