// PullToRefresh.swift
// Mixtape — SharedUI/Components
//
// One definition of what "pull down to refresh" means, so Home, Search and the
// Library all mean the same thing by it.
//
// The gesture is iOS's, and so is the expectation behind it: a page that can be
// pulled is a page the user believes they can force to be current. That is a
// sync — push what this device has changed, take what the others have — not a
// local redraw, which would spin convincingly and change nothing.

import SwiftUI

extension View {

    /// Adds pull-to-refresh, wired to a full sync.
    ///
    /// `extra` runs after the sync for pages with something of their own to
    /// reload — the browse landing, say, which lives in a store the sync has
    /// never heard of.
    ///
    /// A no-op off iOS: the Mac has no pull gesture, and its sidebar refresh
    /// control is the equivalent affordance there.
    @ViewBuilder
    func mixPullToRefresh(_ deps: AppDependencies,
                          extra: (@Sendable () async -> Void)? = nil) -> some View {
        #if os(iOS)
        self.refreshable {
            // The spinner the gesture already draws says "working". This is what
            // keeps the sidebar/status line saying the same thing, so a refresh
            // that outlives the pull still has somewhere to be visible.
            deps.libraryService.beginActivity("Refreshing")
            try? await deps.syncService.sync()
            await extra?()
            deps.libraryService.endActivity()
        }
        #else
        self
        #endif
    }
}
