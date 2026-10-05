// macOS FSEvents watcher for watched folders, so Local Files picks up Finder
// changes. iOS rescans on launch/foreground instead. Events are debounced into
// one scan, and the callback only triggers the same scan the manual path uses.

import Foundation

#if os(macOS)

/// Watches a set of directories and calls back when their contents change.
@MainActor
public final class WatchedFolderMonitor {

    private var stream: FSEventStreamRef?
    private var debounce: Task<Void, Never>?

    /// Quiet time before scanning, so copying an album is one scan.
    private static let settleDelay: Duration = .seconds(2)

    private let onChange: () -> Void

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // `stop()` is main-actor isolated and deinit isn't, so tear down inline.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Replaces the watched set. Called when folders are added or removed.
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
            // Runs on the main run loop, but the compiler can't know that.
            Task { @MainActor in monitor.changed() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // FSEvents latency (seconds), a first coalescing pass before the debounce.
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
