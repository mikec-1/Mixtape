// ModelStore.swift
// Mixtape — Data Layer
//
// Which SwiftData store is open, and whose it is.

import Foundation
import SwiftData

/// The store that is open right now, and the account it belongs to.
///
/// Every account gets its own file. Signing out leaves that file exactly where
/// it is, so signing back in is a file open rather than a five-minute re-pull
/// of a library this device already had — which is what "log out of Spotify,
/// log back in, everything is where you left it" actually costs.
///
/// Before this there was one `default.store` that accounts took turns in, and
/// a different user signing in wiped it. Coming back to your own account
/// therefore showed 0 songs, then spent minutes re-downloading rows and covers
/// the disk had held the whole time.
///
/// The rule that falls out: nothing may *hold* a `ModelContext`. It belongs to
/// whichever store is open now, so everything that reads the database asks
/// `shared` for one at the moment it reads.
@MainActor
public final class ModelStore {

    public static let shared = ModelStore()

    /// The marker `AppDependencies` writes on sign-in. Read here as well, so
    /// the right file is open before auth has restored anything.
    public static let lastUserKey = "mix.lastSignedInUserID"

    /// Built on demand so that `open(for:)` can *release* the outgoing store
    /// before anything touches its file — the one-time adoption in
    /// `ModelContainerSetup` renames `default.store`, and renaming a database
    /// SQLite still has open is asking for it.
    public var container: ModelContainer {
        if let openContainer { return openContainer }
        let made = ModelContainerSetup.makeContainer(for: ownerID)
        openContainer = made
        return made
    }

    private var openContainer: ModelContainer?

    /// The account whose file is open. `nil` only before anyone has ever
    /// signed in on this device.
    public private(set) var ownerID: UUID?

    /// The main-actor context. Computed on purpose — see the type's note.
    public var context: ModelContext { container.mainContext }

    private init() {
        // Whoever was last signed in is whose rows are on disk, so the right
        // file is known synchronously, long before the session restores.
        ownerID = UserDefaults.standard.string(forKey: Self.lastUserKey)
            .flatMap(UUID.init(uuidString:))
    }

    /// Points the app at `userID`'s own store, and says whether it moved.
    @discardableResult
    public func open(for userID: UUID) -> Bool {
        guard ownerID != userID else { return false }
        // Whatever the outgoing account had in flight is theirs, and belongs in
        // their file rather than on the floor.
        try? container.mainContext.save()
        // Every cached cover was keyed on a row in the file about to close —
        // and the scratch context holding them is the last thing keeping the
        // outgoing container alive.
        ArtworkProvider.shared.invalidateAll()
        openContainer = nil
        ownerID = userID
        print("[ModelStore] Switched to the store for \(userID.uuidString)")
        return true
    }
}
