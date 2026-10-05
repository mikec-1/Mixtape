import Foundation

/// Replays this device's adds and removes since `base` onto the server's list, so a
/// stale copy can't bring back songs another device removed. New songs go at the end.
/// Checked by `scripts/track-merge-check.swift`.
nonisolated func mergeTrackIDs(base: [UUID], local: [UUID], server: [UUID]) -> [UUID] {
    if server == base { return local }
    let baseSet = Set(base), localSet = Set(local), serverSet = Set(server)
    let removed = baseSet.subtracting(localSet)
    let added = local.filter { !baseSet.contains($0) && !serverSet.contains($0) }
    return server.filter { !removed.contains($0) } + added
}
