// RepositorySaveBatch.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

/// Collapses a run of repository writes into a single `ModelContext.save()`.
///
/// Every repository save commits on its own, which is right for a one-off edit
/// and badly wrong for a loop. Saving a mix files ~30 songs into their album and
/// artist buckets, and each song costs a `findOrCreate` save plus one save per
/// credited artist — well over a hundred commits, each of them tens of
/// milliseconds. None is slow enough to cross the 100 ms instrumentation
/// threshold, which is why this cost was invisible in the log while the app sat
/// there frozen for a second or two (much longer on the phone).
///
/// Inside a batch the repositories mutate the context and skip the commit; the
/// batch commits once at the end. Reads are unaffected — uncommitted changes are
/// visible to the context that made them, so anything the loop looks up mid-run
/// still sees its own earlier writes.
@MainActor
public enum RepositorySaveBatch {

    private static var depth = 0

    /// True while a batch is open, i.e. while commits should be deferred.
    public static var isOpen: Bool { depth > 0 }

    /// Runs `body` with repository commits held, then commits once.
    ///
    /// The commit happens even if `body` throws: the writes are already in the
    /// context either way, and leaving them uncommitted only means losing them
    /// at the next launch.
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
