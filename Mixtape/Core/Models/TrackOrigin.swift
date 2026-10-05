// Where a track's audio comes from. Stored, not inferred.

import Foundation

public enum TrackOrigin: String, Codable, Hashable, Sendable, CaseIterable {

    /// The user's own file. Uploaded and synced.
    case imported

    /// Saved from Discover. Metadata only, fetched on demand, never uploaded.
    case online

    /// A shared song this library can't find or resolve. Upgrades in place.
    case unresolvableShare

    /// A watched-folder file. Derived by scanning, never persisted or synced.
    /// Promoting it runs the normal import.
    case localFile

    /// A speed/reverb edit of another song. The recipe syncs; each device renders its own file.
    case edit

    /// True when audio has to be fetched from the network before it can play.
    public var requiresResolution: Bool { self == .online }

    /// Audio that isn't Mixtape's to copy, upload or sync.
    public var isOutsideLibraryStorage: Bool { self == .online || self == .localFile || self == .edit }
}
