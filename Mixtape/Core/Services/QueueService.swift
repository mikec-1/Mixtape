// QueueService.swift
// Mixtape — Core/Services
//
// Manages the active play queue, current position, shuffle, and repeat mode.
// PlaybackEngine owns a QueueService and drives it forward/backward.
// Views observe QueueService directly for UI state (current track, shuffle badge, etc.)

import Foundation
import Combine

// MARK: - Repeat Mode

public enum RepeatMode: String, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }

    public var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - Queue Service

@MainActor
public final class QueueService: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var queue:            [Track]     = []
    @Published public private(set) var currentIndex:     Int         = -1
    @Published public private(set) var shuffleEnabled:   Bool        = false
    @Published public private(set) var repeatMode:       RepeatMode  = .off
    /// The playlist the currently playing track originated from. Nil when playing
    /// from a non-playlist context (e.g. artist page, queue-only).
    @Published public private(set) var sourcePlaylistID: UUID?       = nil

    // MARK: - Private

    /// Unshuffled order — restored when shuffle is turned off.
    private var originalQueue: [Track] = []

    // MARK: - Derived

    public var currentTrack: Track? {
        guard currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    public var hasNext: Bool {
        switch repeatMode {
        case .off: return currentIndex < queue.count - 1
        case .all, .one: return !queue.isEmpty
        }
    }

    public var hasPrevious: Bool {
        currentIndex > 0 || (repeatMode == .all && !queue.isEmpty)
    }

    // MARK: - Queue Loading

    /// Replace the queue with `tracks` and start at `track`.
    public func play(track: Track, in tracks: [Track]) {
        originalQueue = tracks
        if shuffleEnabled {
            queue        = shuffled(from: tracks, startingWith: track)
            currentIndex = 0
        } else {
            queue        = tracks
            currentIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        }
    }

    /// Wipe the queue entirely — called when the current track is deleted from the library
    /// so the mini-player returns to a "Nothing playing" state.
    public func clearCurrentTrack() {
        queue         = []
        originalQueue = []
        currentIndex  = -1
        sourcePlaylistID = nil
    }

    /// Record which playlist triggered the current playback session.
    public func setSourcePlaylist(_ id: UUID?) {
        sourcePlaylistID = id
    }

    /// Restore a minimal single-track queue (used for resume-on-launch).
    /// Sets up `queue`/`originalQueue` with just `track` and points currentIndex at it,
    /// without altering shuffle/repeat. PlaybackEngine drives the actual load.
    public func restoreSession(track: Track) {
        originalQueue = [track]
        queue         = [track]
        currentIndex  = 0
    }

    // MARK: - Navigation

    /// The track `advance()` *would* return, without mutating queue state.
    /// Used by the crossfade engine to pre-load the upcoming track.
    public func peekNext() -> Track? {
        guard !queue.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return queue[currentIndex]
        case .all:
            return queue[(currentIndex + 1) % queue.count]
        case .off:
            guard currentIndex + 1 < queue.count else { return nil }
            return queue[currentIndex + 1]
        }
    }

    /// Advance one step. Returns the track to play next, or nil if the queue ended.
    public func advance() -> Track? {
        guard !queue.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return queue[currentIndex]
        case .all:
            currentIndex = (currentIndex + 1) % queue.count
            return queue[currentIndex]
        case .off:
            guard currentIndex + 1 < queue.count else { return nil }
            currentIndex += 1
            return queue[currentIndex]
        }
    }

    /// Go back one step. Returns the track to play.
    public func previous() -> Track? {
        guard !queue.isEmpty else { return nil }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        }
        return queue[currentIndex]
    }

    // MARK: - Queue Editing

    /// Insert `track` immediately after the current position ("Play Next").
    public func insertNext(_ track: Track) {
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertAt)
        originalQueue.append(track)
    }

    /// Append `track` to the end of the queue ("Add to Queue").
    public func append(_ track: Track) {
        queue.append(track)
        originalQueue.append(track)
    }

    /// Reorder the queue, moving the item at `source` to `destination`.
    /// Keeps `currentIndex` pointing at the same currently-playing track and keeps
    /// `originalQueue` consistent. Bounds-guarded; no-op on invalid indices.
    public func moveQueueItem(from source: Int, to destination: Int) {
        guard source != destination else { return }
        guard queue.indices.contains(source) else { return }
        // destination may equal queue.count when conceptually "moving to the end",
        // but here we treat it as an index that must be within bounds.
        guard destination >= 0, destination < queue.count else { return }

        // Identify the currently-playing track so we can re-find it after the move.
        let playingID = currentTrack?.id

        let moved = queue.remove(at: source)
        queue.insert(moved, at: destination)

        // Re-point currentIndex at the same track it referenced before the move.
        if let playingID, let newIndex = queue.firstIndex(where: { $0.id == playingID }) {
            currentIndex = newIndex
        }

        // Keep originalQueue consistent. When shuffle is off, originalQueue mirrors
        // queue, so mirror the move there too. When shuffle is on, originalQueue is
        // the pre-shuffle order; reordering the shuffled view shouldn't disturb it,
        // but if the same items are present we mirror by moving the same track id.
        if !shuffleEnabled {
            originalQueue = queue
        } else if let origSource = originalQueue.firstIndex(where: { $0.id == moved.id }) {
            let origMoved = originalQueue.remove(at: origSource)
            let clampedDest = min(destination, originalQueue.count)
            originalQueue.insert(origMoved, at: clampedDest)
        }
    }

    // MARK: - Shuffle

    public func toggleShuffle() {
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            queue        = shuffled(from: originalQueue, startingWith: current)
            currentIndex = 0
        } else {
            queue        = originalQueue
            currentIndex = originalQueue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    // MARK: - Repeat

    public func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    // MARK: - Private

    private func shuffled(from tracks: [Track], startingWith first: Track) -> [Track] {
        var rest = tracks.filter { $0.id != first.id }.shuffled()
        rest.insert(first, at: 0)
        return rest
    }
}
