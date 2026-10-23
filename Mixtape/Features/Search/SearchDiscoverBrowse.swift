// The Search tab's landing: genre tiles under "Browse all".
// iOS only; the Mac has the Discover section.

#if os(iOS)
import SwiftUI

/// Reads the Discover tab's landing from `DiscoverSessionStore`, so both share one cache.
struct SearchDiscoverBrowse: View {

    let onOpen: (DiscoverDestination) -> Void

    @Environment(AppDependencies.self) private var deps
    private var store: DiscoverSessionStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.browse.isEmpty && store.browseLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }

            if !store.browse.genres.isEmpty {
                Text("Browse all")
                    .font(.mixTitle.bold())
                    .foregroundStyle(Color.mixTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(store.browse.genres.enumerated()), id: \.element.id) { index, genre in
                        IOSGenreTile(genre: genre, index: index) {
                            onOpen(.genre(genre))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .task { store.loadBrowseIfNeeded(using: deps.itunesClient) }
    }
}
#endif
