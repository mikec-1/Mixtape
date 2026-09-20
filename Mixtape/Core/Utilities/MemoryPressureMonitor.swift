// MemoryPressureMonitor.swift
// Mixtape — Core/Utilities
//
// Gives memory back before the system takes the app away.
//
// The app had no memory-warning handling at all. On the Mac that mostly shows
// up as swap; on iOS it is the difference between a jettison and a survivable
// hiccup, and Mixtape is a heavy target for one — it holds four image caches
// with a combined allowance of ~224 MB on top of a library whose artwork lives
// in SwiftData blobs.
//
// A `DispatchSource` memory-pressure source rather than
// `UIApplicationDidReceiveMemoryWarning`: it works on both platforms from one
// piece of code, and it distinguishes *warning* from *critical*, which deserve
// different answers.

import Foundation
import Dispatch
import os

public final class MemoryPressureMonitor: @unchecked Sendable {

    public static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Begin listening. Idempotent — a second call is ignored rather than
    /// stacking a second source that would purge everything twice.
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

        // Downloaded remote covers first: every byte is re-fetchable and the
        // grid that wanted them is usually not even on screen any more.
        RemoteImageCache.shared.purge()

        // Then the decoded bitmaps. These are the expensive ones — a decode is
        // several times the size of the blob it came from — and the blobs are
        // still in the database, so this only costs a re-decode.
        ArtworkDecodeCache.shared.purge()

        // Under real pressure, give up the blob caches as well. Not on a plain
        // warning: those are read straight back out on the next draw, and
        // dropping them turns a warning into a burst of database reads at
        // exactly the moment the device is struggling.
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
