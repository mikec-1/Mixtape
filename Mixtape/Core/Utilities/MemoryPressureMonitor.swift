// Frees caches on memory pressure. A DispatchSource works on both platforms
// and distinguishes warning from critical.

import Foundation
import Dispatch
import os

public final class MemoryPressureMonitor: @unchecked Sendable {

    public static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Idempotent.
    public func start() {
        guard source == nil else { return }

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            self.handle(event)
        }
        src.resume()
        source = src
    }

    private func handle(_ event: DispatchSource.MemoryPressureEvent) {
        let critical = event.contains(.critical)

        // Remote covers first; all re-fetchable.
        RemoteImageCache.shared.purge()

        // Then decoded bitmaps; the blobs are still in the database.
        ArtworkDecodeCache.shared.purge()

        // Blob caches only when critical; dropping them on a warning just causes a
        // burst of database reads.
        if critical {
            Task { @MainActor in
                ArtworkProvider.shared.invalidateAll()
                ArtworkImageLoader.shared.invalidateAll()
            }
        }

        MixLog.hangs.warning(
            "Memory pressure (\(critical ? "critical" : "warning", privacy: .public)) — image caches purged"
        )
    }
}
