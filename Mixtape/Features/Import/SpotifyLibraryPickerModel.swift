// The listing and migration logic of the Spotify library import, shared by the
// sheet and the Spotify connection in Settings.

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
    /// Sections that failed to load, in words, so a missing section isn't mistaken for an empty one.
    @Published public private(set) var warnings: [String] = []
    @Published public var isConnecting = false

    /// Keep imports in sync with Spotify afterwards. Off by default: a mirror makes
    /// the playlist read-only.
    @Published public var keepInSync = false

    @Published public var progress: SpotifyImportService.MigrationProgress?
    @Published public var result: SpotifyImportService.MigrationResult?

    private let spotifyClient: SpotifyClient
    private let importService: SpotifyImportService
    private let auth: SpotifyAuth
    /// Nil only in previews and tests; the toggle is hidden then.
    private let followService: SpotifyFollowService?

    /// Stops two listings at once: hosts load after `connect()` and again when `isAuthorized` flips.
    private var isLoading = false
    private var migration: Task<Void, Never>?

    /// Nil only in previews and tests; rows then lack the imported badge.
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

    /// Selected rows imported before, for the note under the list.
    public var selectedAlreadyImported: [SpotifyLibraryItem] {
        guard let ledger else { return [] }
        return items.filter { selection.contains($0.id) && ledger.hasImported($0) }
    }

    /// Whether to offer "keep in sync". Not for albums, which have no playlist to mirror.
    public var canFollow: Bool {
        followService != nil
            && items.contains { selection.contains($0.id) && $0.kind != .album }
    }

    // MARK: - Derived

    /// Not `Section`, which SwiftUI already uses.
    public struct PickerSection {
        public let title: String
        public let items: [SpotifyLibraryItem]
    }

    /// Grouped and filtered: saved songs, playlists, then albums.
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

    /// Songs the import would bring: full counts for new items, only the gain for imported ones.
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
        // "All" skips already-imported items; a second tap selects the rest.
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
            // Shown above the list; what did load is still usable.
            warnings = fetched.missing.map(\.sentence)
            // Nothing pre-ticked.
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

    /// Turns a finished import into links. Only items that landed (`destinations`),
    /// so a failed playlist never becomes a mirror.
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

    /// Records landed items in the ledger for the "already imported" badge. Uses
    /// `completedItemIDs`, so stopped (rolled back) and failed items aren't recorded.
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

    /// Back to the chooser after a run without refetching, which would lose the scroll.
    public func startOver() {
        result = nil
        progress = nil
        selection = []
        phase = items.isEmpty ? .idle : .choosing
    }
}
