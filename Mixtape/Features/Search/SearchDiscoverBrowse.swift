// SearchDiscoverBrowse.swift
// Mixtape — Features/Search
//
// The catalogue half of the Search tab's landing: Spotify-style genre tiles
// under "Browse all". Records and artists live on Home; Search is where people
// go looking, so its landing offers places to look rather than things to play.
//
// iOS only. The Mac reaches all of this through the Discover section.

#if os(iOS)
import SwiftUI

/// Reads the same `DiscoverSessionStore` landing the Discover tab does rather
/// than fetching its own: the two tabs then share one cache and one 30-minute
/// TTL, so opening Search after Home costs nothing.
struct SearchDiscoverBrowse: View {

    let onOpen: (DiscoverDestination) -> Void

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var store = DiscoverSessionStore.shared

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
