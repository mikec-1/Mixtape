// PlaylistSortSyncService.swift
// Mixtape — Core/Services
//
// The one place the chosen playlist sort order lives, and the only thing that
// carries it between a Mac and a phone signed into the same account.
//
// The order used to be a per-device preference, which was defensible while the
// Mac sidebar and the iOS Library were separate lists — it stopped being so
// once both screens started drawing the same order from the same shared
// `LibrarySortOrder.sorted(_:)`. Picking "Alphabetical" is a statement about
// how someone reads their library, not about the machine they're sitting at.
//
// Carried in Supabase Auth's `user_metadata` rather than a table of its own:
// it's one short string per account, it's already fetched with every session,
// and writing it triggers the `.userUpdated` event that refreshes `authState`
// app-wide — so a new device picks it up on sign-in with no migration and no
// RLS policy to get wrong. See `SupabaseAuthService.updatePlaylistSortOrder`.

import Foundation
import Combine

@MainActor
public final class PlaylistSortSyncService: ObservableObject {

    public static let shared = PlaylistSortSyncService()

    /// The chosen order. Both `MacAppState.playlistSortOrder` and iOS's
    /// `LibraryViewModel.sortOrder` mirror this, in both directions.
    @Published public var sortOrder: LibrarySortOrder = .manual {
        didSet {
            guard sortOrder != oldValue else { return }
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.key)
            // A change that came *from* the account must not be pushed back at
            // it: the round trip is harmless but it burns an auth write and an
            // `.userUpdated` event on every sign-in.
            guard !isApplyingRemote else { return }
            pushWriter?(sortOrder.rawValue)
        }
    }

    /// Set by `AppDependencies` — writes the raw value into `user_metadata`.
    /// Left nil in previews and tests, where the value is simply local.
    public var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private static let key = "library.sortOrder"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = LibrarySortOrder(rawValue: raw) {
            sortOrder = saved
        }
    }

    /// Takes the account's stored order as authoritative — called whenever the
    /// authenticated user changes. A signed-in account's choice wins over
    /// whatever this device happened to be showing; that's the whole point of
    /// syncing it. An account that has never chosen one (nil) leaves the local
    /// value alone rather than resetting a device to `.manual`.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let order = LibrarySortOrder(rawValue: raw), order != sortOrder else { return }
        isApplyingRemote = true
        sortOrder = order
        isApplyingRemote = false
    }
}
