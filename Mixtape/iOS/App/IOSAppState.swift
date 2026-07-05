// IOSAppState.swift
// Mixtape — iOS/App
//
// Window-level state for the iOS app.
// Holds the metadata review queue shown after imports.
// Mirrors the review-queue slice of MacAppState.

#if os(iOS)
import SwiftUI
import Combine

final class IOSAppState: ObservableObject {

    // MARK: - Tab Selection

    /// The selected top-level tab. Held here (rather than as local @State in
    /// MainTabView) so navigation requests originating outside a tab — e.g.
    /// tapping an artist in the mini player or now-playing sheet — can switch
    /// tabs programmatically.
    @Published var selectedTab: AppTab = .home

    // MARK: - Cross-tab Artist Navigation
    //
    // The mini player and now-playing sheet live ABOVE the per-tab
    // NavigationStacks, so they can't push directly. Instead they set one of
    // these pending requests; the owning tab consumes it and drives its own
    // NavigationStack (mirrors the macOS `showArtist` / `showOnlineArtist`
    // intent on MacAppState).

    /// A local library artist to push on the Library tab's stack.
    @Published var pendingLibraryArtist: Artist? = nil

    /// An artist name to resolve + push on the Discover tab's stack (used when no
    /// local library artist matches — e.g. a featured artist on a saved song).
    @Published var pendingDiscoverArtistName: String? = nil

    /// Route a tapped artist name to the right tab/profile: a matching local
    /// library artist opens the Library artist page; otherwise the name is
    /// resolved online and opened in Discover. Mirrors macOS's per-name routing.
    func openArtist(name: String, library: LibraryService) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let artist = library.artist(named: trimmed) {
            pendingLibraryArtist = artist
            selectedTab = .library
        } else {
            pendingDiscoverArtistName = trimmed
            selectedTab = .discover
        }
    }

    // MARK: - Metadata Review Queue

    /// Enrichment candidates waiting for user review, shown one at a time.
    @Published private(set) var reviewQueue: [MetadataReviewItem] = []

    /// The item currently shown in the review sheet (front of queue).
    var pendingReview: MetadataReviewItem? { reviewQueue.first }

    /// Total items in the current review batch (resets when queue drains to zero).
    private(set) var batchTotal = 0

    /// 1-based index of the item currently being reviewed.
    var currentItemNumber: Int {
        guard batchTotal > 0 else { return 1 }
        return batchTotal - reviewQueue.count + 1
    }

    func enqueueReview(_ item: MetadataReviewItem) {
        if reviewQueue.isEmpty { batchTotal = 0 }   // fresh batch
        reviewQueue.append(item)
        batchTotal += 1
    }

    func dequeueReview() {
        if !reviewQueue.isEmpty { reviewQueue.removeFirst() }
        if reviewQueue.isEmpty  { batchTotal = 0 }
    }
}
#endif
