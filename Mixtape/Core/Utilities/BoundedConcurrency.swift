// Runs work with a fixed number in flight, keeping results in input order.
// An unbounded task group floods the network and gets 429s.

import Foundation

/// `transform` over every item, at most `limit` at a time, in input order.
/// Non-throwing so one failure doesn't abandon the rest; return an optional instead.
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
