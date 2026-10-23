// Type-ahead rows under the search field. Separate from DiscoverSessionStore, which
// holds committed results; these are throwaway.
// Only Discover feeds this. Rows the library already has float to the top, keeping
// Deezer's order within each group.

import Foundation
import Combine
import Observation

@Observable
@MainActor
final class SearchSuggestionsStore {

    static let shared = SearchSuggestionsStore()

    private init() { recents = Self.loadRecents() }

    // MARK: - State

    private(set) var suggestions: [SearchSuggestion] = []

    /// Rows the user picked, newest first. Shown when the field is focused and empty.
    private(set) var recents: [SearchSuggestion] = []

    /// True while the dropdown is standing in for an empty query.
    private(set) var showsRecents = false

    /// What the dropdown draws. Everything downstream reads this so recents behave like suggestions.
    var rows: [SearchSuggestion] { showsRecents ? recents : suggestions }

    /// Keyboard row, nil for none. Down enters at 0; up off the top gives the caret back.
    var highlighted: Int?

    /// Set by Esc, Return or picking a row. Cleared by the next keystroke.
    private(set) var isDismissed = false

    /// The query `suggestions` answer, so a slow old response can't overwrite newer rows.
    @ObservationIgnored private var loadedQuery = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    /// A picked completion. Writing it into the field looks like typing, so this stops
    /// the panel reopening. Cleared by the next edit.
    @ObservationIgnored private var acceptedQuery: String?

    private static let debounce = Duration.milliseconds(140)

    /// Quiet time before a keystroke counts as the start of typing.
    private static let leadIn: TimeInterval = 0.5

    /// When a request last went out, after the debounce.
    @ObservationIgnored private var lastDispatch = Date.distantPast

    var isShowing: Bool { !isDismissed && !rows.isEmpty }

    // MARK: - Loading

    func update(query text: String,
                using catalog: ITunesSearchClient,
                library: LibraryService? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if let accepted = acceptedQuery {
            guard trimmed != accepted else { return }
            acceptedQuery = nil
        }

        if isDismissed { isDismissed = false }

        guard trimmed.count >= 2 else {
            clear()
            showsRecents = !recents.isEmpty
            return
        }
        showsRecents = false
        guard trimmed != loadedQuery else { return }

        task?.cancel()
        let startingToType = Date().timeIntervalSince(lastDispatch) > Self.leadIn

        task = Task { @MainActor in
            // The first keystroke of a burst goes out immediately; the debounce applies from the second.
            if !(self.suggestions.isEmpty && startingToType) {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            self.lastDispatch = Date()

            let rows = await catalog.searchSuggestions(query: trimmed)
            guard !Task.isCancelled else { return }

            self.loadedQuery = trimmed
            self.suggestions = Self.preferringLibrary(rows,
                                                      library: library)
            // Never carry a highlight across result sets, or Return plays a different song.
            self.highlighted = nil

            // A typed line reads as lyrics: those hits land on top once they arrive.
            guard trimmed.split(separator: " ").count >= 4 else { return }
            let hits = await catalog.searchByLyrics(trimmed, limit: 2)
            guard !Task.isCancelled, !hits.isEmpty else { return }
            let lyricRows = hits.compactMap(SearchSuggestion.init(lyricMatch:))
            let ids = Set(lyricRows.map(\.id))
            self.suggestions = lyricRows + self.suggestions.filter { !ids.contains($0.id) }
            self.highlighted = nil
        }
    }

    /// Marks rows the library has and floats them up. A stable partition, so Deezer's
    /// order holds within each group.
    private static func preferringLibrary(_ rows: [SearchSuggestion],
                                          library: LibraryService?) -> [SearchSuggestion] {
        guard let library else { return rows }
        let marked = rows.map { row -> SearchSuggestion in
            var row = row
            switch row.kind {
            case .track:
                // By recording, not id, like the save button.
                row.inLibrary = library.track(matching: row.title,
                                              artistName: row.artistName ?? "") != nil
            case .artist:
                row.inLibrary = library.artist(named: row.title) != nil
            case .album, .term:
                break
            }
            return row
        }
        return marked.filter(\.inLibrary) + marked.filter { !$0.inLibrary }
    }

    /// Hide the dropdown but keep the rows for re-focus.
    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        highlighted = nil
    }

    /// Like `dismiss()`, but the field write this causes won't reopen the panel.
    func accept(_ query: String) {
        acceptedQuery = query.trimmingCharacters(in: .whitespaces)
        isDismissed = true
        highlighted = nil
    }

    func clear() {
        task?.cancel()
        task = nil
        loadedQuery = ""
        acceptedQuery = nil
        suggestions = []
        highlighted = nil
        isDismissed = false
        showsRecents = false
    }

    // MARK: - Recents

    /// Record a row the user opened. Deduplicated by id, newest first.
    func remember(_ row: SearchSuggestion) {
        var row = row
        row.inLibrary = false          // stale by tomorrow; recomputed on show
        recents.removeAll { $0.id == row.id }
        recents.insert(row, at: 0)
        if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
        saveRecents()
    }

    /// Record a plain query the user committed with Return.
    func rememberTerm(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        remember(SearchSuggestion(id: "term:" + trimmed.lowercased(), kind: .term,
                                  title: trimmed, subtitle: nil, imageURL: nil,
                                  isExplicit: false, artistName: nil, albumTitle: nil))
    }

    /// Forget a past search. Recents only: hiding a live result would hide it from search entirely.
    func hide(_ row: SearchSuggestion) {
        recents.removeAll { $0.id == row.id }
        if showsRecents { showsRecents = !recents.isEmpty }
        highlighted = nil
        saveRecents()
    }

    func clearRecents() {
        recents = []
        showsRecents = false
        saveRecents()
    }

    private static let recentsLimit = 20

    private static let recentsURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        let dir = base.appendingPathComponent("Mixtape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-recents.json")
    }()

    private static func loadRecents() -> [SearchSuggestion] {
        guard let data = try? Data(contentsOf: recentsURL) else { return [] }
        return (try? JSONDecoder().decode([SearchSuggestion].self, from: data)) ?? []
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: Self.recentsURL, options: .atomic)
    }

    // MARK: - Keyboard

    /// Moves the highlight. False when it can't (up from the top row), so the caller
    /// decides what the key does.
    @discardableResult
    func moveHighlight(_ direction: HighlightMove) -> Bool {
        guard isShowing else { return false }
        switch direction {
        case .down:
            highlighted = min((highlighted ?? -1) + 1, rows.count - 1)
            return true
        case .up:
            guard let current = highlighted else { return false }
            highlighted = current == 0 ? nil : current - 1
            return true
        }
    }

    enum HighlightMove { case up, down }

    var highlightedSuggestion: SearchSuggestion? {
        guard let highlighted, rows.indices.contains(highlighted) else { return nil }
        return rows[highlighted]
    }
}

// MARK: - Turning a row into something playable

extension SearchSuggestion {

    /// Rebuilt from the fields the search carried, so a tap doesn't refetch.
    /// `.term` has nothing behind it and re-runs the search.
    var onlineTrack: OnlineTrack? {
        guard case .track(let id) = kind else { return nil }
        return OnlineTrack(
            title: title,
            artistName: artistName ?? "",
            albumTitle: albumTitle ?? "",
            duration: duration ?? 0,
            artworkURL: imageURL,
            sourceID: id,
            isExplicit: isExplicit
        )
    }

    var onlineArtist: OnlineArtist? {
        guard case .artist(let id) = kind else { return nil }
        return OnlineArtist(id: id, name: title, imageURL: imageURL)
    }

    var onlineAlbum: OnlineAlbum? {
        guard case .album(let id) = kind else { return nil }
        return OnlineAlbum(id: id, title: title, artistName: artistName ?? "", coverURL: imageURL)
    }

    /// Symbol for a row with no artwork.
    var placeholderIcon: String {
        switch kind {
        case .term:   return "magnifyingglass"
        case .artist: return "music.mic"
        case .track:  return "music.note"
        case .album:  return "square.stack"
        }
    }

    /// A song played from search results, with the suggestions API's id shape so both
    /// dedupe to one recent.
    init?(track: OnlineTrack) {
        guard let id = track.sourceID else { return nil }
        self.init(id: "track-\(id)",
                  kind: .track(id: id),
                  title: track.title,
                  subtitle: track.artistName.isEmpty ? "Song" : "Song • \(track.artistName)",
                  imageURL: track.artworkURL,
                  isExplicit: track.isExplicit,
                  artistName: track.artistName,
                  albumTitle: track.albumTitle,
                  duration: track.duration > 0 ? track.duration : nil)
    }

    /// A song found by its lyrics, labelled so the match makes sense.
    init?(lyricMatch track: OnlineTrack) {
        guard let id = track.sourceID else { return nil }
        self.init(id: "track-\(id)",
                  kind: .track(id: id),
                  title: track.title,
                  subtitle: track.artistName.isEmpty ? "Lyrics match" : "Lyrics match • \(track.artistName)",
                  imageURL: track.artworkURL,
                  isExplicit: track.isExplicit,
                  artistName: track.artistName,
                  albumTitle: track.albumTitle,
                  duration: track.duration > 0 ? track.duration : nil)
    }

    /// Same, for an artist or album the user opened out of the results.
    init(artist: OnlineArtist) {
        self.init(id: "artist-\(artist.id)", kind: .artist(id: artist.id),
                  title: artist.name, subtitle: "Artist",
                  imageURL: artist.imageURL, isExplicit: false)
    }

    init(album: OnlineAlbum) {
        self.init(id: "album-\(album.id)", kind: .album(id: album.id),
                  title: album.title,
                  subtitle: album.artistName.isEmpty ? "Album" : "Album • \(album.artistName)",
                  imageURL: album.coverURL, isExplicit: false,
                  artistName: album.artistName)
    }

    var isCircular: Bool {
        if case .artist = kind { return true }
        return false
    }
}
