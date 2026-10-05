// Which file an account's rows live in, and the one-time move onto that name.

import Foundation

/// File naming and moves for `ModelStore`, kept as plain Foundation so it can be tested.
enum StoreFileLayout {

    /// The SQLite files that must move and be deleted together, or the last writes are lost.
    static let companions = ["", "-wal", "-shm"]

    /// The name every account shared before stores were split per account.
    static let sharedName = "default.store"

    /// Store for `owner`. Nil (never signed in) keeps the old shared name.
    static func storeURL(for owner: UUID?, in directory: URL) -> URL {
        guard let owner else { return directory.appendingPathComponent(sharedName) }
        return directory.appendingPathComponent("library-\(owner.uuidString.lowercased()).store")
    }

    /// One-time rename of the old shared store to the last signed-in account. That
    /// user owns its contents, so a rename is the whole migration.
    /// Returns whether it moved anything. Refuses if the account already has a store.
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

    /// Deletes a store and its journal. Only for recovering a store that won't open.
    static func remove(storeAt url: URL, fileManager fm: FileManager = .default) {
        for suffix in companions {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
