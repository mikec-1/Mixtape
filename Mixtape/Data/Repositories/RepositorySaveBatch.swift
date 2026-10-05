import Foundation
import SwiftData

/// Collapses a run of repository writes into one `ModelContext.save()`.
/// Each repository save commits on its own, which adds up in loops (saving a mix
/// is 100+ commits). Inside a batch they skip the commit and the batch commits once.
/// Reads still see the uncommitted writes.
@MainActor
public enum RepositorySaveBatch {

    private static var depth = 0

    /// True while a batch is open, i.e. while commits should be deferred.
    public static var isOpen: Bool { depth > 0 }

    /// Runs `body` with commits held, then commits once, even if `body` throws.
    @discardableResult
    public static func run<T>(_ context: ModelContext, _ body: () throws -> T) rethrows -> T {
        depth += 1
        defer {
            depth -= 1
            if depth == 0 { try? context.save() }
        }
        return try body()
    }
}

extension ModelContext {
    /// `save()`, unless a `RepositorySaveBatch` is holding commits.
    @MainActor
    func saveBatched() throws {
        guard !RepositorySaveBatch.isOpen else { return }
        try save()
    }
}
