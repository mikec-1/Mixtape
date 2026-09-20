// SearchSuggestionsStore.swift
// Mixtape — Features/Online
//
// The type-ahead rows under the search field.
//
// Separate from DiscoverSessionStore on purpose. That one holds results the user
// committed to and wants back when they return to the tab; this one is throwaway
// — it exists only while a field has focus and is wrong the moment the query
// changes. Mixing the two would mean a tab switch restoring a stale dropdown.
//
// Only Discover feeds this. The library sections filter what is already on
// screen as you type, so a dropdown of Deezer rows over them would offer to
// navigate away from the very results the field is narrowing.
//
// The rows are Deezer's, the order isn't. Deezer ranks by what the world plays;
// a search box in a music library is nearly always someone reaching for
// something they already own, and burying their own song under four global hits
// with similar names is the wrong answer to the question they asked. So every
// row is checked against the library and the ones you have float to the top,
// keeping Deezer's order within each group.

import Foundation
import Combine

@MainActor
final class SearchSuggestionsStore: ObservableObject {

    static let shared = SearchSuggestionsStore()

    private init() { recents = Self.loadRecents() }

    // MARK: - State

    @Published private(set) var suggestions: [SearchSuggestion] = []

    /// Rows the user actually picked, newest first. Shown when the field is
    /// focused with nothing typed — an empty box is a question with no answer,
    /// and the likeliest answer is something they reached for before.
    @Published private(set) var recents: [SearchSuggestion] = []

    /// True while the dropdown is standing in for an empty query.
    @Published private(set) var showsRecents = false

    /// What the dropdown is actually drawing. Everything downstream —
    /// highlighting, Return, both platform panels — goes through this so
    /// recents behave exactly like live suggestions.
    var rows: [SearchSuggestion] { showsRecents ? recents : suggestions }

    /// Row the keyboard is on, nil when no row is selected. ↓ from the text
    /// field enters the list at 0; ↑ off the top leaves it nil again, which puts
    /// the caret back in charge without closing the dropdown.
    @Published var highlighted: Int?

    /// Set when the user is done with the dropdown for this query — Esc, Return,
    /// or picking a row. Cleared by the next keystroke, so dismissing doesn't
    /// suppress suggestions for the rest of the session.
    @Published private(set) var isDismissed = false

    /// Query `suggestions` answer. Guards against a slow response for an old
    /// query landing on top of a newer one's rows.
    private var loadedQuery = ""
    private var task: Task<Void, Never>?

    /// A completion the user picked. Picking one writes it into the field, which
    /// looks exactly like typing from here — without this the panel would reopen
    /// on the very term it was just closed with. Cleared by the next real edit.
    private var acceptedQuery: String?

    /// Fast enough to feel live, slow enough that a typed word is a handful of
    /// requests rather than one per character.
    private static let debounce = Duration.milliseconds(140)

    /// How long the field has to have been quiet before a keystroke is treated
    /// as the *start* of typing rather than the middle of it.
    private static let leadIn: TimeInterval = 0.5

    /// When a request last actually went out — measured after the debounce, so
    /// it tracks requests rather than keystrokes.
    private var lastDispatch = Date.distantPast

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

        // A keystroke means the user is still looking — undo any earlier dismiss.
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
            // The first rows of a query go out on the keystroke itself.
            //
            // A debounce buys the right thing in the middle of a word — the user
            // is reading rows that are already up while the next set resolves, so
            // a beat of staleness costs nothing and saves a request per
            // character. It buys nothing at the start of one: there is nothing on
            // screen to read, and the delay is just the panel refusing to appear,
            // which is the only thing about it anyone ever notices. So the
            // debounce applies from the second keystroke of a burst onward.
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
            // Never carry a highlight across a result set — index 2 of the old
            // rows is a different song in the new ones, and Return would play it.
            self.highlighted = nil
        }
    }

    /// Marks the rows the library already has and floats them to the top.
    ///
    /// A stable partition, not a sort: within each group Deezer's ranking is
    /// still the best answer, and reordering it would only make the dropdown
    /// jump around as the library grows.
    private static func preferringLibrary(_ rows: [SearchSuggestion],
                                          library: LibraryService?) -> [SearchSuggestion] {
        guard let library else { return rows }
        let marked = rows.map { row -> SearchSuggestion in
            var row = row
            switch row.kind {
            case .track:
                // By recording, not by id — an imported song is the same song
                // under a different spelling. Same rule the save button uses.
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

    /// Hide the dropdown but keep the rows, so re-focusing the field without
    /// retyping brings them straight back.
    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        highlighted = nil
    }

    /// The user picked a term completion, and `query` is now in the field. Same
    /// as `dismiss()`, except the write it is about to cause won't reopen us.
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

    /// Forget a past search. Only ever a recent: live results are what the
    /// catalogue matched for the query you just typed, and removing one of
    /// those made an artist vanish from search entirely.
    func hide(_ row: SearchSuggestion) {
        recents.removeAll { $0.id == row.id }
        if showsRecents { showsRecents = !recents.isEmpty }
        highlighted = nil
        saveRecents()
    }

    /// Rows vetoed this session — see `hide`.

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

    /// Moves the highlight. Returns false when the move can't be made — ↑ from the
    /// top row — so the caller can decide what the key should do instead.
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

    /// The entity behind this row, rebuilt from the fields the search layer
    /// carried over rather than re-fetched. Deezer already told us everything a
    /// play or a drill-down needs; a round-trip on tap would only add latency to
    /// the one moment the user is waiting.
    ///
    /// `.term` has nothing behind it — it re-runs the search instead.
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

    /// SF Symbol standing in for a row with no artwork. Deezer serves covers for
    /// most tracks and albums but plenty of small artists have no photo.
    var placeholderIcon: String {
        switch kind {
        case .term:   return "magnifyingglass"
        case .artist: return "music.mic"
        case .track:  return "music.note"
        case .album:  return "square.stack"
        }
    }

    /// A row standing for a song the user played out of the search results.
    /// Same id shape the suggestions API uses, so a song reached either way
    /// dedupes to one recent.
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
