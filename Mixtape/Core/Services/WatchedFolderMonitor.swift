// WatchedFolderMonitor.swift
// Mixtape — Core/Services
//
// Notices when a watched folder changes, so Local Files keeps up with Finder
// without anyone pressing anything.
//
// macOS only, and deliberately so. FSEvents watches a directory tree from
// outside the app, which is exactly the shape of this problem: the user drops an
// album into their music folder in Finder and expects Mixtape to have it. iOS
// has no equivalent for a folder in the Files app that another process owns, so
// there the launch/foreground rescan remains the whole story.
//
// Two things this is careful about:
//
//   • It coalesces. A copy of an album is hundreds of events over a few seconds,
//     and a scan per event would be hundreds of scans of the same folder. Events
//     are debounced, so a busy copy costs one scan after it settles.
//   • It never decides anything. The callback's only job is to say "look again";
//     the scan itself is the same derived scan as everywhere else, so live
//     watching cannot introduce a state the manual path wouldn't also reach.

import Foundation

#if os(macOS)

/// Watches a set of directories and calls back when their contents change.
@MainActor
public final class WatchedFolderMonitor {

    private var stream: FSEventStreamRef?
    private var debounce: Task<Void, Never>?

    /// How long to wait after the last event before scanning. Long enough that
    /// copying an album is one scan, short enough that dropping in a single file
    /// feels immediate.
    private static let settleDelay: Duration = .seconds(2)

    private let onChange: () -> Void

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // `stop()` is main-actor isolated and deinit is not, so the teardown is
        // spelled out here rather than borrowed from it.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Points the monitor at exactly these directories, replacing whatever it
    /// was watching. Called again whenever the user adds or removes a folder.
    public func watch(_ urls: [URL]) {
        stop()
        guard !urls.isEmpty else { return }

        let paths = urls.map { $0.path(percentEncoded: false) } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WatchedFolderMonitor>.fromOpaque(info)
                .takeUnretainedValue()
            // FSEvents calls back on the run loop it was scheduled on — the main
            // one here — but the compiler can't know that, so hop explicitly.
            Task { @MainActor in monitor.changed() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Latency in seconds. A first coalescing pass inside FSEvents itself,
            // before the debounce below.
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        debounce?.cancel()
        debounce = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Something changed. Wait for the folder to stop changing, then say so once.
    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}

#endif
