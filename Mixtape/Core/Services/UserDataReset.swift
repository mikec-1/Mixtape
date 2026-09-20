// UserDataReset.swift
// Mixtape — Core/Services
//
// One announcement for "the ground this was built on just moved".
//
// A lot of what the app shows isn't stored, it's *derived* — the Discover
// landing's mixes and recommendations, the Home shelf, the recent-artists row,
// the recently-played list. Each of those has its own cache with its own
// lifetime, and each was written assuming its inputs only ever grow.
//
// They don't. Clear Everything and Delete All Music remove the inputs outright,
// and until this existed nothing told the derived layers about it: the week's
// mixes are pinned to a file in Application Support, the personal landing sits
// in memory behind a six-hour TTL, and both survived a wipe intact. The result
// was a home page built from a listening history that no longer existed —
// "Made for you" cards for artists the user no longer had, under a line that
// read "Built from  and the rest of your listening history" because the seeds
// it names were gone.
//
// So resets are announced, once, and every derived layer subscribes. Adding a
// new derived feature means subscribing to this; it does not mean finding and
// editing every destructive command in Settings.

import Foundation

/// What a reset took with it. Derived state drops whatever it was built from.
public struct UserDataReset: Sendable {

    /// The library — songs, albums, artists, artwork — is gone.
    public let clearedLibrary: Bool
    /// The play log and its snapshots are gone, so top artists, seeds and any
    /// "because you listened to…" claim no longer have anything behind them.
    public let clearedHistory: Bool
    /// True when this is one account's local copy being dropped because a
    /// *different* account signed in — not a wipe anybody asked for.
    ///
    /// Derived state rebuilds either way: it was built from the outgoing
    /// account's library. State that follows the account is the exception. By
    /// the time this lands, the incoming account's own copy has already been
    /// adopted, so clearing it deletes the wrong person's records — and, for
    /// anything that pushes, uploads that deletion to their account. Those
    /// listeners skip this reset and take their new contents from
    /// `accountDidChange` instead.
    public let isAccountSwitch: Bool

    /// "Clear Everything" — nothing is left to build from.
    public static let everything = UserDataReset(clearedLibrary: true, clearedHistory: true)
    /// "Delete All Music" — the history stands (it's a record of what was
    /// listened to, not of what is owned), but everything keyed to owning the
    /// songs has to be rebuilt.
    public static let library    = UserDataReset(clearedLibrary: true, clearedHistory: false)
    /// A different account signed in on this device, so the last one's local
    /// rows have been dropped. See `isAccountSwitch`.
    public static let accountSwitch = UserDataReset(clearedLibrary: true,
                                                    clearedHistory: true,
                                                    isAccountSwitch: true)

    public init(clearedLibrary: Bool, clearedHistory: Bool, isAccountSwitch: Bool = false) {
        self.clearedLibrary = clearedLibrary
        self.clearedHistory = clearedHistory
        self.isAccountSwitch = isAccountSwitch
    }

    // MARK: - Broadcast

    /// Announce a reset. Safe to call from anywhere; listeners hop to the main
    /// actor themselves.
    public static func announce(_ reset: UserDataReset) {
        NotificationCenter.default.post(name: .mixUserDataReset,
                                        object: nil,
                                        userInfo: [Self.key: reset])
    }

    /// Pull the payload out of a posted notification. A notification without one
    /// is read as the widest reset rather than ignored — a listener that guesses
    /// wrong here should guess toward rebuilding.
    public static func from(_ notification: Notification) -> UserDataReset {
        notification.userInfo?[Self.key] as? UserDataReset ?? .everything
    }

    private static let key = "reset"
}

extension Notification.Name {
    /// Posted after the user's library and/or listening history has been wiped.
    /// Everything derived from either listens for it. See `UserDataReset`.
    public static let mixUserDataReset = Notification.Name("mix.userDataReset")
}
