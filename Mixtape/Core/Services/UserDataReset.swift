// Announces that user data was wiped, so every derived layer (mixes, Home
// shelves, recent artists, recently played) rebuilds. New derived features
// subscribe to this instead of being cleared by each destructive command.

import Foundation

/// What a reset took with it. Derived state drops whatever it was built from.
public struct UserDataReset: Sendable {

    /// The library (songs, albums, artists, artwork) is gone.
    public let clearedLibrary: Bool
    /// Play history is gone, so seeds and "because you listened to" are too.
    public let clearedHistory: Bool
    /// A different account signed in, not a user wipe. Derived state still
    /// rebuilds, but account-synced state is skipped: the incoming account's copy is
    /// already adopted, and clearing it would delete (and push) their data. Those
    /// listeners use `accountDidChange` instead.
    public let isAccountSwitch: Bool

    /// "Clear Everything": nothing is left to build from.
    public static let everything = UserDataReset(clearedLibrary: true, clearedHistory: true)
    /// "Delete All Music": history stays, everything tied to owned songs rebuilds.
    public static let library    = UserDataReset(clearedLibrary: true, clearedHistory: false)
    /// Previous account's rows dropped. See `isAccountSwitch`.
    public static let accountSwitch = UserDataReset(clearedLibrary: true,
                                                    clearedHistory: true,
                                                    isAccountSwitch: true)

    public init(clearedLibrary: Bool, clearedHistory: Bool, isAccountSwitch: Bool = false) {
        self.clearedLibrary = clearedLibrary
        self.clearedHistory = clearedHistory
        self.isAccountSwitch = isAccountSwitch
    }

    // MARK: - Broadcast

    /// Safe from any thread; listeners hop to main themselves.
    public static func announce(_ reset: UserDataReset) {
        NotificationCenter.default.post(name: .mixUserDataReset,
                                        object: nil,
                                        userInfo: [Self.key: reset])
    }

    /// A missing payload is treated as the widest reset.
    public static func from(_ notification: Notification) -> UserDataReset {
        notification.userInfo?[Self.key] as? UserDataReset ?? .everything
    }

    private static let key = "reset"
}

extension Notification.Name {
    /// Posted after the library and/or history is wiped. See `UserDataReset`.
    public static let mixUserDataReset = Notification.Name("mix.userDataReset")
}
