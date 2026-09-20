// BoundedConcurrency.swift
// Mixtape — Core/Utilities
//
// "Do all of these, but not all at once."
//
// A plain `withTaskGroup` that adds one task per item is unbounded: fine for the
// dozen covers in one playlist, ruinous for the thousands in a whole library.
// Every request leaves at the same instant, the network queue thrashes, and
// Spotify answers the flood with 429s — so the fastest way to ask for
// everything turns out to be the slowest way to get it.
//
// This keeps a fixed number in flight: prime the group with `limit` tasks, then
// start one more each time one finishes. Results come back in the order the
// items were given, not the order they happened to complete.

import Foundation

/// Applies `transform` to every item with at most `limit` running concurrently,
/// returning the results in the original order.
///
/// `transform` can't throw on purpose — one failure shouldn't abandon the work
/// already done. Let it return an optional (or a `Result`) and let the caller
/// decide what a gap means.
func mapConcurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    guard !items.isEmpty else { return [] }

    let cap = max(1, min(limit, items.count))
    var pairs: [(offset: Int, value: Output)] = []
    pairs.reserveCapacity(items.count)

    await withTaskGroup(of: (Int, Output).self) { group in
        var next = 0

        func start() {
            let offset = next
            let item   = items[offset]
            group.addTask { (offset, await transform(item)) }
            next += 1
        }

        while next < cap { start() }

        while let pair = await group.next() {
            pairs.append((pair.0, pair.1))
            if next < items.count { start() }
        }
    }

    return pairs.sorted { $0.offset < $1.offset }.map(\.value)
}
