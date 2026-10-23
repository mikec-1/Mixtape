// The chrome around the library list: header, sort/layout bar and grid cell.
// Same on every section.
// The header is hand-built rather than `navigationTitle` so the avatar sits on
// the title line and the filter pills scroll away without collapsing the title.

import SwiftUI

// MARK: - Header

/// Avatar, title, search, add.
struct LibraryHeader: View {

    @Binding var isSearching: Bool
    @Binding var searchText:  String
    let onAdd: () -> Void

    /// Focuses the field as soon as search opens.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileMenuButton(size: 30)

                Text("Your Library")
                    .font(.system(size: MixFontScale.size(24), weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)

                Spacer(minLength: 8)

                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        isSearching.toggle()
                        // Closing search clears it, so the list never looks filtered with no visible query.
                        if !isSearching { searchText = "" }
                    }
                    if isSearching { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .accessibilityLabel(isSearching ? "Close search" : "Search library")

                InboxButton()
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .buttonStyle(.plain)

                MessagesButton()
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .buttonStyle(.plain)

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .accessibilityLabel("Add")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isSearching {
                LibrarySearchField(text: $searchText, focus: $searchFocused)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct LibrarySearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)

            TextField("Search in Your Library", text: $text)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .focused(focus)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Sort / layout bar

/// "Recents" sort menu on the left, grid/list toggle on the right. The label
/// shows the current order.
struct LibrarySortBar: View {

    @Binding var order:  LibrarySortOrder
    @Binding var layout: LibraryLayout
    /// Hidden on sections that have no meaningful second layout.
    var showsLayoutToggle: Bool = true
    /// Drives drag-to-reorder. Nil, or `canArrange` false, hides the control.
    var arranging: Binding<Bool>? = nil
    var canArrange: Bool = false

    var body: some View {
        HStack {
            Menu {
                // Unlabelled so the options aren't nested in a "Sort by" submenu. See `MacSidebarView`.
                Picker("", selection: $order) {
                    ForEach(LibrarySortOrder.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(order.rawValue)
                        .font(.mixLabel)
                }
                .foregroundStyle(Color.mixTextSecondary)
            }
            .accessibilityLabel("Sort by \(order.rawValue)")

            Spacer()

            if let arranging, canArrange {
                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        arranging.wrappedValue.toggle()
                    }
                } label: {
                    Text(arranging.wrappedValue ? "Done" : "Arrange")
                        .font(.mixLabel)
                        .foregroundStyle(arranging.wrappedValue ? Color.mixPrimary
                                                                : Color.mixTextSecondary)
                }
                .padding(.trailing, 12)
            }

            if showsLayoutToggle {
                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        layout = layout == .list ? .grid : .list
                    }
                } label: {
                    Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .accessibilityLabel(layout == .list ? "Show as grid" : "Show as list")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Playlist descriptor

/// The grey line under a playlist name ("Playlist • mike", "Mix • Mixtape"),
/// shared by row and grid cell.
enum PlaylistDescriptor {

    static func kind(_ playlist: Playlist) -> String {
        if playlist.isSystem { return "Playlist" }
        switch playlist.origin {
        case .owned:         return "Playlist"
        case .mix:           return "Mix"
        case .subscribed:    return "Playlist"
        case .spotifyMirror: return "Spotify"
        }
    }

    /// "Playlist • mike". No owner for unattributed playlists (the user's own).
    static func line(_ playlist: Playlist) -> String {
        guard let owner = playlist.ownerName, !owner.isEmpty else { return kind(playlist) }
        return "\(kind(playlist)) • \(owner)"
    }
}

// MARK: - Grid cell

/// A playlist as a square tile. The grid's answer to `PlaylistRowView`.
struct PlaylistGridCell: View {

    let playlist: Playlist
    @Environment(DownloadManager.self) private var downloads
    private var meta: PlaylistMetadataService { .shared }

    private var isFullyDownloaded: Bool {
        downloads.isFullyDownloaded(playlist.trackIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistArtwork(playlist: playlist, size: nil, cornerRadius: 6)
                .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            HStack(spacing: 4) {
                if meta.isPinned(playlistID: playlist.id) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mixPrimary)
                        .rotationEffect(.degrees(45))
                }
                DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads, size: 10, showsProgress: downloads.isPlaylistOffline(playlist.id))
                Text(PlaylistDescriptor.line(playlist))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name), \(PlaylistDescriptor.line(playlist))")
    }
}
