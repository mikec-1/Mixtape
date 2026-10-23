// The playlist sort order, synced per account via Supabase `user_metadata`
// (already fetched with the session; a write fires `.userUpdated`). See
// `SupabaseAuthService.updatePlaylistSortOrder`.

import Foundation
import Combine
import Observation

@Observable
@MainActor
public final class PlaylistSortSyncService {

    public static let shared = PlaylistSortSyncService()

    /// Mirrored both ways by `MacAppState.playlistSortOrder` and iOS's `LibraryViewModel.sortOrder`.
    public var sortOrder: LibrarySortOrder = .manual {
        didSet {
            guard sortOrder != oldValue else { return }
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.key)
            // Don't push back a value that came from the account.
            guard !isApplyingRemote else { return }
            pushWriter?(sortOrder.rawValue)
        }
    }

    /// Writes the raw value to `user_metadata`. Nil in previews and tests.
    @ObservationIgnored public var pushWriter: ((String) -> Void)?

    @ObservationIgnored private var isApplyingRemote = false
    private static let key = "library.sortOrder"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = LibrarySortOrder(rawValue: raw) {
            sortOrder = saved
        }
    }

    /// The account's order wins, applied on every user change. Nil (never set)
    /// leaves the local value alone.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let order = LibrarySortOrder(rawValue: raw), order != sortOrder else { return }
        isApplyingRemote = true
        sortOrder = order
        isApplyingRemote = false
    }
}
