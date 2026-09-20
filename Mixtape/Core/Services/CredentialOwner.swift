// CredentialOwner.swift
// Mixtape — Core/Services
//
// One rule, shared by every outside connection stored on the device: whose is it?
//
// Spotify's grant lives in the keychain and Last.fm's key, secret and session
// live in UserDefaults, and both were device-global. Signing out of one Mixtape
// account and into another left the first account's connections on screen,
// live, and — for Spotify — republished the outgoing user's refresh token into
// the incoming user's `spotify_connections` row.
//
// The fix is a stamp, and this is the one place that reads it, so the two
// services can't drift apart on the answer.

import Foundation

enum CredentialOwner {

    /// Whether a stored credential may be used by the account signing in.
    ///
    /// - Parameters:
    ///   - owner: the account recorded on the credential, or nil for one stored
    ///     before Mixtape recorded owners.
    ///   - userID: the account signing in now.
    ///   - previous: the account signed in until now, as this device recorded
    ///     it — nil on a device where nobody has signed in yet. Read *before*
    ///     that record moves on.
    ///
    /// An unowned credential belongs to whoever was last signed in here, since
    /// they are the only person who could have made it. That is this user when
    /// they are signing back into the same account, and nobody when somebody
    /// else has signed in since.
    static func belongs(owner: String?, to userID: UUID, previous: String?) -> Bool {
        if let owner { return owner == userID.uuidString }
        return previous == nil || previous == userID.uuidString
    }
}
