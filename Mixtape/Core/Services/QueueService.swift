// QueueService.swift
// Mixtape — Core/Services
//
// Manages the active play queue, current position, shuffle, and repeat mode.
// PlaybackEngine owns a QueueService and drives it forward/backward.
// Views observe QueueService directly for UI state (current track, shuffle badge, etc.)
//
// # The three lanes
//
// The queue is one flat list — that is what `advance()` walks and what the
// player bar reads — but every row belongs to one of three lanes, and the lanes
// are always in this order after the playing row:
//
//     [ now playing ][ manual ][ context ][ recommendation ]
//
//   * `manual`         — songs the user put there by hand ("Add to Queue",
//                        "Play Next"). They play first, and nothing the app
//                        does on its own may reorder or displace them.
//   * `context`        — the playlist / album / artist / search results that
//                        was playing when the user pressed play. Shuffle acts
//                        on this lane and this lane only.
//   * `recommendation` — the top-up the app adds once the context has run out,
//                        so the music keeps going. Shuffle doesn't suppress it
//                        (a shuffled playlist still ends), but repeat does —
//                        repeat is its own answer to "what plays next".
//
// That ordering *is* the feature: it's what lets the queue show "Next in queue"
// above "Next up: <Playlist>" above "Next up: recommended songs", the way
// every other music player does. Every insertion point below is chosen to keep
// it true, so no caller has to think about it.

import Foundation
import Combine

// MARK: - Repeat Mode

public enum RepeatMode: String, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }

    /// Spoken name for the transport button, which otherwise shows the same
    /// glyph for "off" and "all" and reads as nothing at all.
    public var accessibilityLabel: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    public var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - Lanes

/// Why a row is in the queue. See the file header — the ordering of these cases
/// is the ordering of the queue.
public enum QueueOrigin: Int, Comparable, Sendable {
    /// The user asked for this song specifically.
    case manual = 0
    /// Part of the list playback started from.
    case context = 1
    /// The app's own top-up once the context ran out.
    case recommendation = 2

    public static func < (lhs: QueueOrigin, rhs: QueueOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where the context lane came from, so the queue can say "Next up: Liked Songs"
/// rather than the anonymous "Next in queue".
///
/// A bare playlist id was too narrow: albums, artists and search results fill
/// the queue exactly the same way and had nothing to show for it. The playlist
/// case still carries its id because playing state elsewhere (the sidebar's
/// "this playlist is playing" dot) keys off it.
public enum QueueSource: Equatable, Sendable {
    case none
    case playlist(id: UUID, name: String)
    /// An album, artist, search or mix — anything that already knows its own
    /// display name and has no playlist id to match against.
    case named(String)

    public var displayName: String? {
        switch self {
        case .none: return nil
        case .playlist(_, let name): return name.isEmpty ? nil : name
        case .named(let name): return name.isEmpty ? nil : name
        }
    }

    public var playlistID: UUID? {
        if case .playlist(let id, _) = self { return id }
        return nil
    }
}

// MARK: - Queue Service

@MainActor
public final class QueueService: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var queue:            [Track]     = []
    /// One id per row of `queue`, in the same order.
    ///
    /// `Track.id` is a content hash of title + artist, so the same song queued
    /// twice is the *same* id twice and nothing can tell the two rows apart:
    /// SwiftUI drew the second as a blank gap, clicking it played the first, and
    /// dragging it moved the first. These ids identify a row rather than a song,
    /// which is what queueing a song three times in a row needs.
    ///
    /// Kept exactly in step with `queue` by every mutation below — `alignEntryIDs()`
    /// is the backstop.
    @Published public private(set) var entryIDs:         [UUID]      = []
    /// Which lane each row belongs to, keyed by row id.
    ///
    /// Keyed by row rather than by track: queueing a song you already had coming
    /// up marks *that* row, not the other one. A row with no entry here is
    /// context — that is the harmless default for anything restored or mirrored
    /// without lane information.
    @Published public private(set) var origins:          [UUID: QueueOrigin] = [:]
    @Published public private(set) var currentIndex:     Int         = -1
    @Published public private(set) var shuffleEnabled:   Bool        = false
    @Published public private(set) var repeatMode:       RepeatMode  = .off
    /// The last row of the repeating group — the song after which "Repeat queue"
    /// loops back to the top.
    ///
    /// Repeat means "the group as it stood when repeat was switched on", so a
    /// song queued afterwards doesn't silently join the loop and there is a way
    /// to line something up to play *after* it. The boundary is held against a
    /// row id, so rows can be dragged in or out of the group. Nil whenever
    /// repeat isn't `.all`.
    @Published public private(set) var repeatBoundaryID: UUID?       = nil
    /// The list the current playback session came from — named, so the queue can
    /// say where its upcoming songs are from.
    @Published public private(set) var source:           QueueSource = .none

    /// The playlist the currently playing track originated from, or nil when
    /// playback started from something that isn't a playlist. Kept because the
    /// sidebar, the playlists grid and the suggestion service all ask this exact
    /// question.
    public var sourcePlaylistID: UUID? { source.playlistID }

    /// Where the repeating group ends, as a position in the current queue.
    ///
    /// Nil when repeat isn't `.all`, and also when the row that marked the
    /// boundary is gone (removed, or a new list replaced the queue) — callers
    /// treat that as "the whole queue", which is what repeat meant before.
    public var repeatBoundaryIndex: Int? {
        guard repeatMode == .all, let id = repeatBoundaryID else { return nil }
        return entryIDs.firstIndex(of: id)
    }

    /// True for a row that plays only once repeat is switched off — it sits
    /// below the boundary. Used by the queue panels to draw the divider and the
    /// "after repeat" tail.
    public func isAfterRepeatGroup(index: Int) -> Bool {
        guard let boundary = repeatBoundaryIndex else { return false }
        return index > boundary
    }

    // MARK: - Private

    /// The context lane's canonical, unshuffled order, as row ids.
    ///
    /// Only the context lane: shuffle reorders the playlist the user pressed
    /// play on and leaves their own queued songs exactly where they put them,
    /// so the pre-shuffle order of anything else is not something to remember.
    /// Ids the queue no longer holds are pruned lazily by `contextOrderIDs`'s
    /// readers.
    private var contextOrderIDs: [UUID] = []

    // MARK: - Derived

    /// The queue as rows. Each carries its own identity and its position, which
    /// is what the queue lists key off and what click-to-play and drag-to-reorder
    /// name — never the track id, which two rows can share.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id:     UUID
        public let index:  Int
        public let track:  Track
        public let origin: QueueOrigin

        /// The user asked for this row specifically.
        public var isManual: Bool { origin == .manual }
    }

    public var entries: [Entry] {
        let lanes = origins
        return alignedEntryIDs().enumerated().map {
            Entry(id: $1, index: $0, track: queue[$0], origin: lanes[$1] ?? .context)
        }
    }

    /// The row id at `index`, if there is one.
    public func entryID(at index: Int) -> UUID? {
        entryIDs.indices.contains(index) ? entryIDs[index] : nil
    }

    /// The lane a row belongs to. Context is the default for rows that were
    /// never tagged — a restored session, an online mirror pushed without lanes.
    public func origin(at index: Int) -> QueueOrigin {
        guard let id = entryID(at: index) else { return .context }
        return origins[id] ?? .context
    }

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

    // MARK: - Sections

    /// One block of the upcoming queue, with the heading it is shown under.
    ///
    /// Derived on every read rather than stored: the lanes live on the rows, and
    /// two views hand-rolling the same grouping is how the Mac panel and the iOS
    /// sheet would drift apart. Both read this.
    public struct Section: Identifiable, Sendable {
        public let origin: QueueOrigin
        public let title:  String
        public let rows:   [Entry]
        public var id: QueueOrigin { origin }
    }

    /// Everything after the currently playing row — and the whole queue when
    /// nothing is playing yet, which is a real state ("Add to Queue" before
    /// pressing play).
    public var upcomingRows: [Entry] {
        let rows  = entries
        let start = currentIndex + 1
        guard start < rows.count else { return [] }
        return Array(rows[start...])
    }

    /// The upcoming queue split into its lanes, in order, skipping any lane
    /// that has no rows.
    public var upcomingSections: [Section] {
        let rows = upcomingRows
        guard !rows.isEmpty else { return [] }
        return [QueueOrigin.manual, .context, .recommendation].compactMap { lane in
            let laneRows = rows.filter { $0.origin == lane }
            guard !laneRows.isEmpty else { return nil }
            return Section(origin: lane, title: title(for: lane), rows: laneRows)
        }
    }

    /// The heading a lane is shown under.
    ///
    /// Every section names its origin — "Next up: Liked Songs" is the difference
    /// between a list of songs and a list you recognise — and they all share the
    /// one shape, so the panel reads as three answers to the same question:
    ///
    ///     Next in queue
    ///     Next up: Road Trip
    ///     Next up: recommended songs
    ///
    /// The bare fallback is for a queue with no list behind it at all: one built
    /// by hand, or restored from a session whose playlist has since been deleted.
    public func title(for lane: QueueOrigin) -> String {
        switch lane {
        case .manual:         return "Next in queue"
        case .context:        return source.displayName.map { "Next up: \($0)" } ?? "Next up"
        case .recommendation: return "Next up: recommended songs"
        }
    }

    /// How many context-lane rows are still ahead of the current one.
    ///
    /// The suggestion service tops the queue up only when this reaches zero —
    /// recommendations belong *after* the playlist has run out, not spliced in
    /// beside it.
    public var remainingContextCount: Int {
        upcomingRows.reduce(0) { $0 + ($1.origin == .context ? 1 : 0) }
    }

    /// How many recommendation rows are queued ahead — the depth the suggestion
    /// service keeps topped up once it has taken over.
    public var remainingRecommendationCount: Int {
        upcomingRows.reduce(0) { $0 + ($1.origin == .recommendation ? 1 : 0) }
    }

    // MARK: - Queue Loading

    /// Replace the queue with `tracks` and start at `track`.
    ///
    /// Everything handed over is context by definition — it is the list the user
    /// pressed play on. Resets the source; callers that know where the list came
    /// from name it afterwards via `setSource(_:)`.
    ///
    /// `startIndex` names the row to start on when the caller knows it — a click
    /// on the second copy of a song in the queue has to start *that* row, and a
    /// search by track id can only ever find the first. Nil means "find the
    /// song", which is right for every caller that is handing over a list rather
    /// than pointing at a row in one.
    public func play(track: Track, in tracks: [Track], startIndex: Int? = nil) {
        source = .none
        // Songs the user queued by hand are not part of the list being replaced
        // — they were asked for, and pressing play somewhere else is not a
        // request to forget them. They are re-inserted at the head of the new
        // queue below, in order, so they still play before the new list does.
        alignEntryIDs()
        let carriedManual = upcomingSlots(in: .manual).map { queue[$0] }
        // A new list is a new session; an earlier "clear queue" doesn't carry.
        autoQueuePausedForID = nil
        // Where the clicked row sits in the list handed over.
        //
        // The last step used to be `?? 0`, and that one character was a bug with
        // a very confusing face: when the song couldn't be found in its own
        // list, the queue silently started at the top of the playlist instead —
        // click the second song, hear the first, with nothing on screen to say
        // why. Falling back to a *different song* is never the right answer to
        // "I couldn't find the one you asked for", so the miss now carries the
        // clicked track into the queue itself.
        var list  = tracks
        var start = 0
        if let index = startIndex, tracks.indices.contains(index) {
            start = index
        } else if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            start = index
        } else if let index = tracks.firstIndex(where: { Self.isSameSong($0, track) }) {
            // Same song, different row id — a re-import, or a list rebuilt from
            // the library while the click came from somewhere else. It's still
            // the song that was asked for, and its neighbours are still the
            // context the user is looking at.
            start = index
        } else {
            list  = [track] + tracks
            start = 0
        }

        let ids = list.map { _ in UUID() }
        // A new list is all context: whatever was queued by hand belonged to the
        // queue this one replaces.
        origins         = Dictionary(uniqueKeysWithValues: ids.map { ($0, QueueOrigin.context) })
        contextOrderIDs = ids
        if shuffleEnabled, !list.isEmpty {
            // Pressing play with shuffle already on shuffles the *whole* list,
            // not just the part after the song that was clicked: that song
            // leads and the rest of the playlist follows in a random order.
            // (`reshuffleContext` only ever touches what is still upcoming,
            // which is the right rule for the button but not for a new list.)
            var rest = Array(list.indices)
            rest.remove(at: start)
            rest.shuffle()
            let order    = [start] + rest
            queue        = order.map { list[$0] }
            entryIDs     = order.map { ids[$0] }
            currentIndex = 0
        } else {
            queue        = list
            entryIDs     = ids
            currentIndex = list.isEmpty ? -1 : start
        }
        if !carriedManual.isEmpty {
            insert(carriedManual, at: min(currentIndex + 1, queue.count), lane: .manual)
        }
        // A new list is a new group: repeat still applies, but to this queue.
        repeatBoundaryID = repeatMode == .all ? entryIDs.last : nil
    }

    /// "Clear added songs" — drop only what the user queued by hand, leaving the
    /// list they are playing from alone. The mirror image of `clearUpcoming`,
    /// which is the other half people mean by "clear the queue".
    public func clearManualQueue() {
        alignEntryIDs()
        for slot in upcomingSlots(in: .manual).reversed() {
            queue.remove(at: slot)
            entryIDs.remove(at: slot)
        }
        pruneToLiveRows()
    }

    /// Whether there is anything for `clearManualQueue` to do — the button that
    /// calls it hides itself otherwise.
    public var hasManualQueue: Bool { !upcomingSlots(in: .manual).isEmpty }

    /// Whether two rows are the same song wearing different ids. Title and
    /// credited artist only: everything else (album, duration, file) can
    /// legitimately differ between two rows for one song.
    private static func isSameSong(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedSame
        && lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
    }

    /// Wipe the queue entirely — called when the current track is deleted from the library
    /// so the mini-player returns to a "Nothing playing" state.
    public func clearCurrentTrack() {
        queue                = []
        entryIDs             = []
        origins              = [:]
        contextOrderIDs      = []
        currentIndex         = -1
        source               = .none
        repeatBoundaryID     = nil
        autoQueuePausedForID = nil
    }

    /// Name the list this playback session came from.
    public func setSource(_ source: QueueSource) {
        self.source = source
    }

    /// Mirror an online Discover session into the queue purely for display, so the
    /// Queue panel can show its sections for online playback. Actual playback /
    /// navigation is driven by OnlinePlaybackCoordinator (which downloads each
    /// track on demand), not by this queue — so this does NOT touch shuffle,
    /// repeat, or trigger any loading. `index` is the currently-playing position,
    /// or -1 when nothing from the session is playing yet — a queue that has been
    /// filled but not started is a real state, and clamping it to 0 would claim
    /// the first song was playing.
    ///
    /// `lanes` arrives by position and is the coordinator's own record of which
    /// of its slots the user queued by hand; the coordinator maintains the lane
    /// ordering on its side, because during a session *it* is the queue.
    public func setOnlineDisplayQueue(_ tracks: [Track],
                                      currentIndex index: Int,
                                      lanes: [QueueOrigin] = [],
                                      source: QueueSource = .none) {
        // Row ids are carried over where the same song is still there in the same
        // order, so a push that only appends doesn't re-identify every row the
        // panel is already showing (which would drop its animations and rebuild
        // rows that never changed).
        let ids = mixMainActivity("queue/publish-online ▸ carry-ids") {
            carriedEntryIDs(for: tracks)
        }
        mixMainActivity("queue/publish-online ▸ assign") {
            queue           = tracks
            entryIDs        = ids
            origins         = Dictionary(uniqueKeysWithValues: ids.indices.map {
                (ids[$0], lanes.indices.contains($0) ? lanes[$0] : .context)
            })
            contextOrderIDs = ids.indices.filter { (origins[ids[$0]] ?? .context) == .context }
                                         .map { ids[$0] }
        }
        currentIndex    = tracks.isEmpty || index < 0 ? -1 : min(index, tracks.count - 1)
        // Named like every other list: a Discover session is an origin too, and
        // an unnamed one is the only section in the panel that can't say where
        // its songs came from.
        self.source     = source
    }

    // MARK: - Session Snapshot

    /// The queue, small enough to write to defaults and rebuild on next launch.
    ///
    /// Track *ids* rather than tracks: a Track carries its artwork, and the whole
    /// queue's worth of covers has no business in UserDefaults. Row ids are not
    /// carried either — they only have to be unique within a session, and the
    /// restore mints fresh ones.
    public struct Snapshot: Codable, Sendable {
        public var trackIDs:     [UUID]
        /// One lane per id, in the same order.
        public var lanes:        [Int]
        public var currentIndex: Int
        public var playlistID:   UUID?
        public var sourceName:   String?
    }

    public var snapshot: Snapshot {
        let ids = alignedEntryIDs()
        return Snapshot(
            trackIDs:     queue.map(\.id),
            lanes:        ids.map { (origins[$0] ?? .context).rawValue },
            currentIndex: currentIndex,
            playlistID:   source.playlistID,
            sourceName:   source.displayName
        )
    }

    /// Rebuild a saved queue, dropping any song that is no longer in the library.
    ///
    /// `tracks` is the library keyed by id — the caller already has it, and a
    /// lookup per row beats a linear search per row on a queue the size of All
    /// Songs. Returns the track that was playing, or nil when the snapshot has
    /// nothing left to restore.
    @discardableResult
    public func restore(_ snapshot: Snapshot, from tracks: [UUID: Track]) -> Track? {
        var restored: [Track]        = []
        var lanes:    [QueueOrigin]  = []
        var index                    = -1
        for (position, id) in snapshot.trackIDs.enumerated() {
            guard let track = tracks[id] else { continue }
            if position == snapshot.currentIndex { index = restored.count }
            restored.append(track)
            lanes.append(QueueOrigin(rawValue: snapshot.lanes.indices.contains(position)
                                     ? snapshot.lanes[position] : QueueOrigin.context.rawValue)
                          ?? .context)
        }
        guard !restored.isEmpty else { return nil }

        let ids         = restored.map { _ in UUID() }
        queue           = restored
        entryIDs        = ids
        origins         = Dictionary(uniqueKeysWithValues: zip(ids, lanes))
        contextOrderIDs = ids
        // A song that has since been deleted can be the one that was playing;
        // the queue then starts at the top rather than claiming nothing is in it.
        currentIndex    = index >= 0 ? index : 0
        if let id = snapshot.playlistID {
            source = .playlist(id: id, name: snapshot.sourceName ?? "")
        } else if let name = snapshot.sourceName {
            source = .named(name)
        } else {
            source = .none
        }
        repeatBoundaryID = repeatMode == .all ? entryIDs.last : nil
        return currentTrack
    }

    /// Restore a minimal single-track queue (used for resume-on-launch).
    /// Sets up the queue with just `track` and points currentIndex at it,
    /// without altering shuffle/repeat. PlaybackEngine drives the actual load.
    public func restoreSession(track: Track) {
        let id          = UUID()
        origins         = [id: .context]
        contextOrderIDs = [id]
        queue           = [track]
        entryIDs        = [id]
        currentIndex    = 0
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
            let last = repeatBoundaryIndex ?? queue.count - 1
            return currentIndex >= last ? queue[0] : queue[currentIndex + 1]
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
            let last = repeatBoundaryIndex ?? queue.count - 1
            currentIndex = currentIndex >= last ? 0 : currentIndex + 1
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
            // Back from the first song lands on the last song of the *group*,
            // not the last row in the queue — anything past the boundary isn't
            // part of the loop.
            currentIndex = repeatBoundaryIndex ?? queue.count - 1
        }
        return queue[currentIndex]
    }

    // MARK: - Queue Editing

    /// The first upcoming position that isn't in `lane` or an earlier one — i.e.
    /// where a new row of `lane` has to go to keep the lanes in order.
    ///
    /// This is the whole reason "Add to Queue" now behaves: it used to append to
    /// the very end of the list, so a song added while a 40-song playlist was
    /// playing went *behind all forty*. It belongs at the end of the run of
    /// songs the user has already queued, which is what this finds.
    private func insertionIndex(for lane: QueueOrigin) -> Int {
        let start = max(currentIndex + 1, 0)
        var i = min(start, queue.count)
        while i < queue.count, origin(at: i) <= lane { i += 1 }
        return i
    }

    /// Insert `track` at the front of the queue ("Play Next") — it plays before
    /// anything else waiting, including songs queued earlier.
    /// `manual` marks it as the user's own choice. Everything that reaches this
    /// is a menu item, so it defaults to true.
    public func insertNext(_ track: Track, manual: Bool = true) {
        insert([track], at: min(max(currentIndex + 1, 0), queue.count),
               lane: manual ? .manual : .context)
    }

    /// Add `track` to the queue ("Add to Queue") — after anything the user has
    /// already queued, and before the rest of the playlist. A song already in the
    /// queue is added again rather than ignored: queueing the same song twice is
    /// a thing people mean to do.
    public func append(_ track: Track, manual: Bool = true) {
        append(contentsOf: [track], manual: manual)
    }

    /// Add a whole playlist or mix to the queue, as one change rather than one
    /// per song — the list republishes once, so the Queue panel rebuilds once
    /// instead of two dozen times.
    public func append(contentsOf tracks: [Track], manual: Bool = true) {
        append(contentsOf: tracks, lane: manual ? .manual : .recommendation)
    }

    /// Add rows to a specific lane, in the one place that lane's rows belong.
    public func append(contentsOf tracks: [Track], lane: QueueOrigin) {
        guard !tracks.isEmpty else { return }
        insert(tracks, at: insertionIndex(for: lane), lane: lane)
    }

    /// Shared insertion: splice rows in at `index`, tag them, and keep the
    /// context lane's canonical order in step.
    private func insert(_ tracks: [Track], at index: Int, lane: QueueOrigin) {
        guard !tracks.isEmpty else { return }
        alignEntryIDs()
        let at  = min(max(index, 0), queue.count)
        let ids = tracks.map { _ in UUID() }
        queue.insert(contentsOf: tracks, at: at)
        entryIDs.insert(contentsOf: ids, at: at)
        for id in ids { origins[id] = lane }
        // Context rows join the canonical order at the matching place, so that
        // turning shuffle off later puts them back where they were added rather
        // than at the end.
        if lane == .context {
            let before = entryIDs[..<at].filter { (origins[$0] ?? .context) == .context }
            let cut    = before.isEmpty ? 0
                       : (contextOrderIDs.firstIndex(of: before.last!).map { $0 + 1 } ?? contextOrderIDs.count)
            contextOrderIDs.insert(contentsOf: ids, at: min(cut, contextOrderIDs.count))
        }
    }

    /// Fill in cover art that arrived after the row was already queued.
    ///
    /// Queueing a whole mix deliberately does not wait on artwork downloads —
    /// the songs have to land the instant the menu item is clicked — so the
    /// covers arrive a moment later and patch themselves in here. Applied only
    /// where the slot is still artwork-less, so a real cover is never
    /// overwritten.
    public func fillArtwork(_ data: Data, forTrackID id: UUID) {
        for i in queue.indices where queue[i].id == id && queue[i].artworkData == nil {
            queue[i].artworkData = data
        }
    }

    /// The song that was playing when the user last cleared the queue.
    ///
    /// Clearing is an instruction to stop lining songs up, so the auto-queue
    /// has to hear it: it watches the queue shrink and would otherwise refill
    /// the emptied list within the second, which reads as "clear queue does
    /// nothing". It stays paused only for this song — playing anything else is
    /// a new session, and suggestions come back on their own.
    @Published public private(set) var autoQueuePausedForID: UUID? = nil

    /// Stop the auto-queue topping the list up again until something else plays.
    public func pauseAutoQueue() { autoQueuePausedForID = currentTrack?.id }

    /// Drop everything after the current song ("Clear queue").
    ///
    /// Deliberately leaves the playing song alone: clearing the queue is not
    /// "stop the music", in this app or in the one people are used to. With
    /// nothing playing there is nothing to keep, so the whole list goes.
    public func clearUpcoming() {
        pauseAutoQueue()
        alignEntryIDs()
        guard currentIndex >= 0, currentIndex < queue.count else {
            clearCurrentTrack()
            return
        }
        queue.removeSubrange((currentIndex + 1)...)
        entryIDs.removeSubrange((currentIndex + 1)...)
        pruneToLiveRows()
    }

    /// Remove a single row from the queue.
    ///
    /// Refuses the currently-playing row — removing what you are listening to is
    /// a playback command, not a queue edit, and the callers (a row's "Remove
    /// from queue") never offer it there.
    @discardableResult
    public func remove(at index: Int) -> Bool {
        alignEntryIDs()
        guard queue.indices.contains(index), index != currentIndex else { return false }
        queue.remove(at: index)
        entryIDs.remove(at: index)
        pruneToLiveRows()
        if index < currentIndex { currentIndex -= 1 }
        return true
    }

    /// Reorder the queue, moving the item at `source` to `destination`.
    /// `destination` uses SwiftUI `onMove` / `Array.move(fromOffsets:toOffset:)`
    /// semantics: it's the insertion index *before* removal, and may equal
    /// `queue.count` to move an item to the very end.
    ///
    /// Dragging a row across a lane boundary *retags* it: dropping a song into
    /// the middle of the playlist run makes it part of the playlist run. The
    /// alternative — keeping the old tag — would draw a "Next in queue" row
    /// inside the "Next up: …" section, which is a list that contradicts its
    /// own headings.
    public func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source) else { return }
        guard destination >= 0, destination <= queue.count else { return }
        // Moving an item onto itself (or to the slot just after itself) is a no-op.
        guard destination != source, destination != source + 1 else { return }

        alignEntryIDs()

        // Identify the currently-playing *row* so we can re-find it after the
        // move. By row and not by song: with the same song queued twice, the
        // first copy is not necessarily the one playing.
        let playingID = entryID(at: currentIndex)
        let moved     = queue[source]
        let movedID   = entryIDs[source]

        // Manual equivalent of Array.move(fromOffsets:toOffset:) — that helper
        // lives in SwiftUI, which this service deliberately doesn't import.
        // For a downward move the removal shifts later indices left by one, so
        // the effective insertion index is destination - 1.
        let target = destination > source ? destination - 1 : destination
        queue.remove(at: source)
        entryIDs.remove(at: source)
        queue.insert(moved, at: target)
        entryIDs.insert(movedID, at: target)

        // Re-point currentIndex at the same row it referenced before the move.
        if let playingID, let newIndex = entryIDs.firstIndex(of: playingID) {
            currentIndex = newIndex
        }

        retagAfterMove(rowID: movedID)
        rebuildContextOrder()
    }

    /// Give a just-dropped row the lane of the place it landed in.
    ///
    /// Read off its neighbours rather than off pixel positions: the row above it
    /// (skipping the playing row) is the lane it joined, except at the very top
    /// of the upcoming list, where the row *below* decides — a song dropped
    /// above everything is the next thing the user wants to hear, which is the
    /// manual lane.
    private func retagAfterMove(rowID: UUID) {
        guard let index = entryIDs.firstIndex(of: rowID) else { return }
        guard index > currentIndex else {
            // Dropped into the history above the playing song. It plays only if
            // the user scrubs back; treat it as context and leave it alone.
            origins[rowID] = .context
            return
        }
        let above = index - 1 > currentIndex ? origin(at: index - 1) : nil
        let below = index + 1 < queue.count  ? origin(at: index + 1) : nil
        // Between two rows of the same lane there is no ambiguity; at a boundary
        // the row above wins, because a drop lands *after* what it was dropped
        // onto. With nothing above, the lane below is the one being joined.
        origins[rowID] = above ?? below ?? .manual
    }

    // MARK: - Shuffle

    /// Shuffle acts on the context lane — or, when that lane is spent and the
    /// queue is running on recommendations, on those.
    ///
    /// The user's own queued songs are not part of what shuffle means — they
    /// asked for those, in that order — and the recommendations are already
    /// arbitrary. So the playlist's rows are reordered *within the positions the
    /// playlist already occupies*, and every other row stays exactly where it is.
    public func toggleShuffle() {
        setShuffle(!shuffleEnabled)
    }

    /// Put shuffle into a known state rather than flipping it.
    ///
    /// A list whose header says "always shuffle" has to *set* the mode when it
    /// starts playing, not toggle it — toggling turns shuffle off for the list
    /// that asked for it whenever the previous queue happened to be shuffled
    /// already.
    public func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        alignEntryIDs()
        if shuffleEnabled { reshuffleContext() } else { restoreContextOrder() }
    }

    /// Reorder the upcoming context rows at random, in place.
    private func reshuffleContext() {
        reorderUpcoming(in: shuffleLane) { $0.shuffled() }
    }

    /// The lane shuffle acts on: the chosen list, or — once it has run out and
    /// only recommendations are left — those. Pressing shuffle on a station
    /// that has nothing but recommendations ahead of it did nothing at all.
    private var shuffleLane: QueueOrigin {
        upcomingSlots(in: .context).count > 1 ? .context : .recommendation
    }

    /// Put the upcoming context rows back into the order they were added in.
    private func restoreContextOrder() {
        let rank = Dictionary(uniqueKeysWithValues: contextOrderIDs.enumerated().map { ($1, $0) })
        reorderUpcoming(in: shuffleLane) { ids in
            ids.sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
        }
    }

    /// The upcoming rows belonging to `lane`, as queue positions.
    private func upcomingSlots(in lane: QueueOrigin) -> [Int] {
        let start = max(currentIndex + 1, 0)
        guard start < queue.count else { return [] }
        return (start..<queue.count).filter { origin(at: $0) == lane }
    }

    /// Apply `transform` to the ids of the upcoming rows of `lane` and write
    /// them back into the same slots, leaving every other row untouched.
    private func reorderUpcoming(in lane: QueueOrigin, _ transform: ([UUID]) -> [UUID]) {
        let slots = upcomingSlots(in: lane)
        guard slots.count > 1 else { return }

        let byID    = Dictionary(uniqueKeysWithValues: slots.map { (entryIDs[$0], queue[$0]) })
        let ordered = transform(slots.map { entryIDs[$0] })
        for (slot, id) in zip(slots, ordered) {
            entryIDs[slot] = id
            if let track = byID[id] { queue[slot] = track }
        }
    }

    // MARK: - Repeat

    public func cycleRepeat() {
        setRepeat(repeatMode.next)
    }

    /// Set the repeat mode, capturing (or clearing) the group boundary with it.
    ///
    /// Switching to "Repeat queue" fixes the group at whatever is queued right
    /// then; every other mode has no group at all.
    public func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        repeatBoundaryID = mode == .all ? entryIDs.last : nil
    }

    /// Move the end of the repeating group to `rowID` — dragging the divider, or
    /// a row's "repeat up to here". Ignores ids that aren't in the queue.
    public func setRepeatBoundary(rowID: UUID?) {
        guard repeatMode == .all else { return }
        guard let rowID else { repeatBoundaryID = entryIDs.last; return }
        guard entryIDs.contains(rowID) else { return }
        repeatBoundaryID = rowID
    }

    // MARK: - Private

    /// Drop lane tags and canonical-order entries for rows the queue no longer
    /// holds — otherwise both grow without bound across a long session.
    private func pruneToLiveRows() {
        let live = Set(entryIDs)
        origins  = origins.filter { live.contains($0.key) }
        contextOrderIDs.removeAll { !live.contains($0) }
    }

    /// Bring the canonical context order back in line with the queue after a
    /// drag — which may have changed both the order *and*, via `retagAfterMove`,
    /// which rows are in the context lane at all.
    ///
    /// With shuffle off the queue's order simply *is* the canonical order: the
    /// user has just said what they want, and a remembered order that
    /// contradicts it would undo their edit the moment shuffle was switched on
    /// and off again.
    ///
    /// With shuffle on the remembered order has to survive — that is the order
    /// switching shuffle off restores — so only its *membership* is reconciled.
    /// Both halves matter: a row dragged out of the context lane that stayed in
    /// this list would drag a song that is no longer part of the playlist back
    /// into it, and a row dragged *into* the lane that was missing from this
    /// list would rank last and jump to the end of the playlist the moment
    /// shuffle was switched off.
    private func rebuildContextOrder() {
        pruneToLiveRows()
        let contextIDs = entryIDs.filter { (origins[$0] ?? .context) == .context }
        guard shuffleEnabled else {
            contextOrderIDs = contextIDs
            return
        }
        let live = Set(contextIDs)
        contextOrderIDs.removeAll { !live.contains($0) }
        let known = Set(contextOrderIDs)
        for (i, id) in contextIDs.enumerated() where !known.contains(id) {
            // Land it just behind whichever context row precedes it in the
            // queue right now, rather than at the end.
            let after = contextIDs[..<i].last { contextOrderIDs.contains($0) }
            let at    = after.flatMap { contextOrderIDs.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            contextOrderIDs.insert(id, at: min(at, contextOrderIDs.count))
        }
    }

    /// Row ids for a wholesale replacement of the queue, reusing the id of the
    /// row a song already had where the order lines up. Greedy and order-
    /// preserving: an append keeps every existing id, an insert keeps the ids
    /// before it, and anything genuinely new gets a fresh one.
    private func carriedEntryIDs(for tracks: [Track]) -> [UUID] {
        var cursor = 0
        return tracks.map { track in
            if let hit = queue[cursor...].firstIndex(where: { $0.id == track.id }),
               entryIDs.indices.contains(hit) {
                cursor = hit + 1
                return entryIDs[hit]
            }
            return UUID()
        }
    }

    /// Backstop for the one invariant everything here depends on: one row id per
    /// row. Nothing should be able to break it — every mutation above maintains
    /// both arrays — but a mismatch would silently misidentify every row after
    /// the gap, so it is repaired rather than trusted.
    private func alignEntryIDs() {
        guard entryIDs.count != queue.count else { return }
        if entryIDs.count > queue.count {
            entryIDs.removeLast(entryIDs.count - queue.count)
        } else {
            entryIDs.append(contentsOf: (0..<(queue.count - entryIDs.count)).map { _ in UUID() })
        }
    }

    /// `entryIDs`, repaired if it has somehow drifted — used by `entries`, which
    /// is a read and so cannot mutate state.
    private func alignedEntryIDs() -> [UUID] {
        guard entryIDs.count != queue.count else { return entryIDs }
        var ids = Array(entryIDs.prefix(queue.count))
        while ids.count < queue.count { ids.append(UUID()) }
        return ids
    }
}
