// Pull to refresh means a full sync (push local changes, pull remote), not a redraw.

import SwiftUI

extension View {

    /// Adds pull-to-refresh wired to a full sync. `extra` runs afterwards for
    /// pages with their own data (e.g. the browse landing). No-op off iOS.
    @ViewBuilder
    func mixPullToRefresh(_ deps: AppDependencies,
                          extra: (@Sendable () async -> Void)? = nil) -> some View {
        #if os(iOS)
        self.refreshable {
            // Also shows in the status line, in case the refresh outlives the pull.
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
