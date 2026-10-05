// Type-ahead panel under the search field. Drawn by MacRootView, not MacTopBar, so it paints
// over the split view and stays inside the zoom transform.

#if os(macOS)
import SwiftUI

struct MacSearchSuggestions: View {

    @ObservedObject var store: SearchSuggestionsStore
    let onPick: (SearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.showsRecents {
                HStack {
                    Text("Recent searches")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                    Spacer()
                    Button("Clear") { store.clearRecents() }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }

            // Scrolls rather than growing past the player bar.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    isHighlighted: store.highlighted == index,
                    onHover: { hovering in
                        // Pointer and keyboard share one highlight. Leaving a row keeps it lit so Return still works.
                        if hovering { store.highlighted = index }
                    },
                    onTap: { onPick(suggestion) },
                    onRemove: store.showsRecents ? { store.hide(suggestion) } : nil
                )
            }
                }
            }
            .frame(maxHeight: 380)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mixSurface)
                .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        }
        .frame(maxWidth: MacTopBar.searchMaxWidth)
    }
}

// MARK: - Activation

/// Shared by click and Return. Everything but `.term` opens the entity directly.
@MainActor
func activateSuggestion(_ suggestion: SearchSuggestion,
                        appState: MacAppState,
                        deps: AppDependencies) {
    SearchSuggestionsStore.shared.remember(suggestion)

    switch suggestion.kind {
    case .term:
        // `accept` rather than `dismiss`: this write looks like typing and would reopen the panel.
        appState.searchText = suggestion.title
        SearchSuggestionsStore.shared.accept(suggestion.title)
        // Picking a term = pressing Return: show the results and unwind Discover.
        appState.showSearchResults()
        DiscoverSessionStore.shared.commitSearch()

    case .artist:
        guard let artist = suggestion.onlineArtist else { return }
        // Clear anything drawn over the column the page opens in.
        appState.showSearchResults()
        DiscoverSessionStore.shared.path.append(.artist(artist))

    case .album:
        guard let album = suggestion.onlineAlbum else { return }
        appState.showSearchResults()
        DiscoverSessionStore.shared.path.append(.album(album))

    // Playing doesn't navigate; lyrics stay up and follow the new song.
    case .track:
        guard let track = suggestion.onlineTrack else { return }
        Task { await deps.onlineCoordinator.play(track) }
    }
}

// MARK: - Row

private struct SuggestionRow: View {

    let suggestion: SearchSuggestion
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    /// Nil for live results; only past searches can be removed.
    let onRemove: (() -> Void)?

    @State private var hovering = false

    private static let thumb: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                // The rating sits with the title, as on every track list.
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)

                    if suggestion.isExplicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 14, height: 14)
                            .background(Color.mixSurface2,
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // "You have this song". Songs only.
            if suggestion.inLibrary, showsLibraryTick {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixAccentFill)
                    .help("Already in your library")
            }

            // Remove from recents, on hover only.
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Remove from recent searches")
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            // The highlight is the only colour: it's the only state here.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.mixSurface2 : Color.clear)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .onTapGesture(perform: onTap)
    }

    /// Only albums and songs can be in the library.
    private var showsLibraryTick: Bool {
        switch suggestion.kind {
        case .track, .album: return true
        case .artist, .term: return false
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // Terms have no artwork; use the search glyph instead of a grey square.
        if case .term = suggestion.kind {
            Image(systemName: suggestion.placeholderIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: Self.thumb, height: Self.thumb)
        } else {
            CachedRemoteImage(url: suggestion.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: suggestion.placeholderIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: Self.thumb, height: Self.thumb)
            .clipShape(RoundedRectangle(cornerRadius: suggestion.isCircular ? Self.thumb / 2 : 4,
                                        style: .continuous))
        }
    }
}

#endif
