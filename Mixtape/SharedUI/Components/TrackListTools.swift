// Filtering and sorting for a list of songs, plus the search/sort controls
// that sit at the far end of a hero's action row.
// Shared by both platforms: iOS filters a SwiftUI `List`; macOS passes the array
// to an AppKit table whose column headers write into the same `TrackSort`
// (see `NativeTrackTable.sort`), so header clicks and this menu always agree.

import SwiftUI

// MARK: - Model

/// What a list of songs is ordered by.
enum TrackSortField: String, CaseIterable, Identifiable, Hashable {
    /// The playlist's own running order. Always the default; sorts don't outlive the visit.
    case listOrder
    case title
    case artist
    case album
    case dateAdded
    case duration

    var id: String { rawValue }

    /// All fields except `listOrder`, which the page names ("Playlist Order").
    static var sortableFields: [TrackSortField] {
        allCases.filter { $0 != .listOrder }
    }

    var title: String {
        switch self {
        case .listOrder: return "Custom Order"
        case .title:     return "Title"
        case .artist:    return "Artist"
        case .album:     return "Album"
        case .dateAdded: return "Date Added"
        case .duration:  return "Duration"
        }
    }

    /// The Mac table column's `NSSortDescriptor` key. Nil for `listOrder`, which
    /// clears the table's descriptors.
    var sortDescriptorKey: String? {
        switch self {
        case .listOrder: return nil
        case .title:     return "title"
        case .artist:    return "artistName"
        case .album:     return "albumTitle"
        case .dateAdded: return "dateImported"
        case .duration:  return "duration"
        }
    }

    init?(sortDescriptorKey key: String) {
        guard let match = TrackSortField.allCases.first(where: { $0.sortDescriptorKey == key })
        else { return nil }
        self = match
    }
}

struct TrackSort: Equatable {
    var field: TrackSortField = .listOrder
    var ascending: Bool = true

    /// Starting direction: names A-Z, date added newest first.
    static func naturalDirection(for field: TrackSortField) -> Bool {
        field == .dateAdded ? false : true
    }

    /// Picking the current field flips direction, like clicking a column header twice.
    mutating func select(_ field: TrackSortField) {
        if self.field == field {
            ascending.toggle()
        } else {
            self.field = field
            ascending = Self.naturalDirection(for: field)
        }
    }

    var isDefault: Bool { field == .listOrder && ascending }
}

// MARK: - Memoising the derived list

/// Caches a playlist page's visible rows. `visibleTracks` is read many times per
/// body (list, Play, empty state, header count) on lists of thousands of rows,
/// so it's rebuilt only when an input changes. `LibraryService.revision` stands in
/// for the track data. A class in `@State` so it survives struct rebuilds.
@MainActor
final class TrackListMemo {

    private struct Key: Equatable {
        var revision: UInt64
        var ids: [UUID]
        var query: String
        var sort: TrackSort
    }

    private var key: Key?
    private(set) var tracks: [Track] = []
    private(set) var visible: [Track] = []
    private(set) var playable: [Track] = []

    /// Recomputes only if an input changed. `resolve` is passed in, not held, so
    /// this keeps no reference to the library.
    func update(revision: UInt64,
                ids: [UUID],
                query: String,
                sort: TrackSort,
                resolve: (UUID) -> Track?,
                isPlayable: (Track) -> Bool) {
        let next = Key(revision: revision, ids: ids, query: query, sort: sort)
        guard key != next else { return }
        key = next

        tracks   = ids.compactMap(resolve)
        visible  = tracks.matching(query: query).sorted(by: sort)
        playable = visible.filter(isPlayable)
    }
}

// MARK: - Applying it

extension Array where Element == Track {

    /// Rows matching `query` in title, artist or album. Folded, so "beyonce" finds "Beyoncé".
    func matching(query: String) -> [Track] {
        let needle = query.folded
        guard !needle.isEmpty else { return self }
        return filter { track in
            track.title.folded.contains(needle)
                || track.artistName.folded.contains(needle)
                || track.albumTitle.folded.contains(needle)
        }
    }

    /// Sorted by `sort`. Keys are built once per row (`folded` isn't cheap).
    func sorted(by sort: TrackSort) -> [Track] {
        guard sort.field != .listOrder else {
            return sort.ascending ? self : reversed()
        }

        let ordered: [Track]
        switch sort.field {
        case .listOrder:
            ordered = self
        case .title:
            ordered = sortedByKey { $0.title.folded }
        case .artist:
            ordered = sortedByKey { $0.artistName.folded }
        case .album:
            ordered = sortedByKey { $0.albumTitle.folded }
        case .dateAdded:
            ordered = sortedByKey { $0.dateImported }
        case .duration:
            ordered = sortedByKey { $0.duration }
        }
        return sort.ascending ? ordered : ordered.reversed()
    }

    /// Decorate-sort-undecorate: `key` is evaluated once per element.
    private func sortedByKey<K: Comparable>(_ key: (Track) -> K) -> [Track] {
        map { (key($0), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

private extension String {
    /// Case-, accent- and width-insensitive; same fold as `LibraryTrackIndex`.
    var folded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The controls

/// Search field and sort menu for the end of a hero's action row. The field
/// starts collapsed to a single button.
struct TrackListTools: View {

    @Binding var query: String
    @Binding var sort: TrackSort

    /// What the list's own order is called here.
    var listOrderTitle: String = "Custom Order"

    /// Field placeholder; naming the list ("Search in Road Trip") helps.
    var searchPrompt: String = "Search"

    @State private var isSearchOpen = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchControl
            sortMenu
        }
        .mixAnimation(.mixSnappy, value: isSearchOpen)
    }

    // MARK: Search

    @ViewBuilder
    private var searchControl: some View {
        if isSearchOpen {
            HStack(spacing: 6) {
                Image(systemName: MixtapeIcons.search)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.mixTextSecondary)

                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextPrimary)
                    .focused($isFieldFocused)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            // Fixed width on the Mac; on iOS it takes the rest of the row.
            #if os(macOS)
            .frame(width: 200)
            #else
            .frame(maxWidth: .infinity)
            #endif
            .background(Color.mixSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
            // Esc closes it, exactly where the cancel button would be on iOS.
            #if os(macOS)
            .onExitCommand { closeSearch() }
            #endif
            // Losing focus while empty closes it; a field with a query stays open.
            .onChange(of: isFieldFocused) { _, focused in
                if !focused, query.isEmpty { isSearchOpen = false }
            }
            // Hands ⌘⌫ to the field (clear line) instead of the app's delete shortcut.
            .mixEditingFocus(isFieldFocused)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        } else {
            Button {
                isSearchOpen = true
                // Next runloop: focus set in the same update as the view appears is dropped.
                DispatchQueue.main.async { isFieldFocused = true }
            } label: {
                HeroCircleLabel(systemImage: MixtapeIcons.search,
                                foreground: query.isEmpty ? .mixTextSecondary : .mixPrimary,
                                fill: query.isEmpty ? .mixSurface : Color.mixPrimary.opacity(0.18),
                                diameter: 36)
            }
            .buttonStyle(.plain).mixHandCursor()
            .help("Search in this playlist")
            .accessibilityLabel("Search in this playlist")
        }
    }

    private func closeSearch() {
        query = ""
        isFieldFocused = false
        isSearchOpen = false
    }

    // MARK: Sort

    private var sortMenu: some View {
        Menu {
            Button {
                sort.select(.listOrder)
            } label: {
                label(listOrderTitle, checked: sort.field == .listOrder)
            }

            Divider()

            ForEach(TrackSortField.sortableFields) { field in
                Button {
                    sort.select(field)
                } label: {
                    label(field.title, checked: sort.field == field)
                }
            }

            // Offered for list order too (seeing the newest additions of a long playlist).
            // Named for the order ("reverse") rather than ascending/descending.
            Divider()
            Button {
                sort.ascending.toggle()
            } label: {
                Label(directionTitle, systemImage: sort.ascending ? "arrow.down" : "arrow.up")
            }
        } label: {
            sortLabel
        }
        #if os(macOS)
        // Otherwise a Menu draws a bordered pop-up with a chevron.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help("Sort this playlist")
    }

    /// The state you'd land in, which is what the arrow means.
    private var directionTitle: String {
        switch (sort.field, sort.ascending) {
        case (.listOrder, true):  return "Reverse Order"
        case (.listOrder, false): return "Original Order"
        case (_, true):           return "Descending"
        case (_, false):          return "Ascending"
        }
    }

    /// Checkmark in the title; Menu buttons can't show `Toggle` state.
    private func label(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
            }
        }
    }

    /// Names the current order so a re-sorted list is obvious.
    private var sortLabel: some View {
        HStack(spacing: 6) {
            // Neutral glyph for the default order, a direction otherwise.
            Image(systemName: sort.isDefault
                  ? "arrow.up.arrow.down"
                  : (sort.ascending ? "arrow.up" : "arrow.down"))
                .font(.system(size: 12, weight: .bold))
            if !isSearchOpen || sort.field != .listOrder {
                Text(sort.field == .listOrder ? listOrderTitle : sort.field.title)
                    .font(.mixCaptionBold)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(sort.isDefault ? Color.mixTextSecondary : Color.mixPrimary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(sort.isDefault ? Color.mixSurface : Color.mixPrimary.opacity(0.18),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}
