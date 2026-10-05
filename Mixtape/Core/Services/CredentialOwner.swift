// Decides whether a stored credential belongs to the signing-in account,
// so connections don't leak between accounts.

import Foundation

enum CredentialOwner {

    /// An unowned credential belongs to whoever last signed in on this device.
    static func belongs(owner: String?, to userID: UUID, previous: String?) -> Bool {
        if let owner { return owner == userID.uuidString }
        return previous == nil || previous == userID.uuidString
    }
}
