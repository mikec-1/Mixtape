// StoreFileLayout.swift
// Mixtape — Data Layer
//
// Which file an account's rows live in, and the one-time move onto that name.

import Foundation

/// The naming and the file moves behind `ModelStore`, kept apart from SwiftData
/// so the part that can lose a 130 MB library is plain, testable Foundation.
enum StoreFileLayout {

    /// A SQLite database is three files. The journal has to travel with the
    /// database: a `-wal` left behind holds committed pages the `.store` alone
    /// does not have yet, and deleting one without the others leaves a store
    /// that opens and is missing its last writes.
    static let companions = ["", "-wal", "-shm"]

    /// The name every account shared before stores were split per account.
    static let sharedName = "default.store"

    /// Where `owner`'s rows live. A `nil` owner — nobody has ever signed in on
    /// this device — keeps the old shared name.
    static func storeURL(for owner: UUID?, in directory: URL) -> URL {
        guard let owner else { return directory.appendingPathComponent(sharedName) }
        return directory.appendingPathComponent("library-\(owner.uuidString.lowercased()).store")
    }

    /// Hands the old shared store to the account that owns it, once.
    ///
    /// Until per-account stores, every account took turns in one file and a
    /// different user signing in wiped it — so whatever is in it belongs to the
    /// last user signed in, which is whoever is opening it here. Renaming is the
    /// whole migration: anything that re-downloaded instead would make the
    /// upgrade itself look like the empty library this change exists to stop.
    ///
    /// Returns whether it moved anything. Refuses when the account already has
    /// a store, so it can never run twice or overwrite a real library.
    @discardableResult
    static func adoptSharedStore(at url: URL, owner: UUID?, fileManager fm: FileManager = .default) -> Bool {
        guard owner != nil, !fm.fileExists(atPath: url.path) else { return false }
        let shared = url.deletingLastPathComponent().appendingPathComponent(sharedName)
        guard fm.fileExists(atPath: shared.path) else { return false }
        for suffix in companions {
            try? fm.moveItem(at: URL(fileURLWithPath: shared.path + suffix),
                             to: URL(fileURLWithPath: url.path + suffix))
        }
        return true
    }

    /// Deletes a store and its journal. Used only to recover from a store that
    /// will not open at all.
    static func remove(storeAt url: URL, fileManager fm: FileManager = .default) {
        for suffix in companions {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
