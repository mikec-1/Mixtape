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
