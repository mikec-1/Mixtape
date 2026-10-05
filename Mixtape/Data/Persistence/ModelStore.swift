// Which SwiftData store is open, and whose it is.

import Foundation
import SwiftData
import OSLog

/// The open store and its owner. Each account has its own file, left in place on
/// sign-out, so signing back in just reopens it instead of re-pulling.
/// Nothing may hold a `ModelContext`: ask `shared` for one each time.
@MainActor
public final class ModelStore {

    public static let shared = ModelStore()

    /// Written by `AppDependencies` on sign-in; read here so the right file opens before auth restores.
    public static let lastUserKey = "mix.lastSignedInUserID"

    /// Built on demand so `open(for:)` can release the old store before its file is
    /// renamed (see `ModelContainerSetup`).
    public var container: ModelContainer {
        if let openContainer { return openContainer }
        let made = ModelContainerSetup.makeContainer(for: ownerID)
        openContainer = made
        return made
    }

    private var openContainer: ModelContainer?

    /// Nil only if nobody has signed in on this device.
    public private(set) var ownerID: UUID?

    /// Computed on purpose, see the type's note.
    public var context: ModelContext { container.mainContext }

    private init() {
        // The last signed-in user owns what's on disk, known before the session restores.
        ownerID = UserDefaults.standard.string(forKey: Self.lastUserKey)
            .flatMap(UUID.init(uuidString:))
    }

    /// Points the app at `userID`'s own store, and says whether it moved.
    @discardableResult
    public func open(for userID: UUID) -> Bool {
        guard ownerID != userID else { return false }
        // Save the outgoing account's pending changes into its own file.
        try? container.mainContext.save()
        // Cached covers belong to the closing store, and the scratch context would keep it alive.
        ArtworkProvider.shared.invalidateAll()
        openContainer = nil
        ownerID = userID
        MixLog.database.debug("[ModelStore] Switched to the store for \(userID.uuidString)")
        return true
    }
}
