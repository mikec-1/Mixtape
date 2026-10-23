// The play queue, position, shuffle and repeat. PlaybackEngine drives it; views
// observe it directly.
// One flat list, but every row after the playing one belongs to a lane, always
// in this order:
// [ now playing ][ manual ][ context ][ recommendation ]
// - manual: "Add to Queue" / "Play Next". Plays first, never reordered by the app.
// - context: the list the user pressed play on. Shuffle only touches this lane.
// - recommendation: autoplay top-up once context runs out. Repeat suppresses it.
// Every insertion below keeps that order.

import Foundation
import Combine
import Observation

// MARK: - Repeat Mode

public enum RepeatMode: String, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }

    /// VoiceOver name; "off" and "all" share a glyph.
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

/// Why a row is queued. Case order is queue order.
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

/// Where the context lane came from, for "Next up: Liked Songs". Playlists keep
/// their id for the sidebar's playing indicator.
public enum QueueSource: Equatable, Sendable {
    case none
    case playlist(id: UUID, name: String)
    /// Album, artist, search or mix: just a display name.
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

    /// How a play row remembers where it came from. A playlist keeps its id;
    /// everything else (album, artist, search, mix) has only a display name, so
    /// that is the handle. Nil means there is no source worth recording.
    public var historyRef: (kind: String, id: String)? {
        switch self {
        case .none: return nil
        case .playlist(let id, _): return ("playlist", id.uuidString)
        case .named(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : ("name", trimmed)
        }
    }
}

// MARK: - Queue Service

@MainActor @Observable
public final class QueueService {

    // MARK: - Observed State

    public private(set) var queue:            [Track]     = [] { didSet { queueSubject.send(queue) } }
    /// One id per row of `queue`. `Track.id` is a content hash, so a song queued
    /// twice needs row ids to tell the copies apart. `alignEntryIDs()` is the backstop.
    public private(set) var entryIDs:         [UUID]      = []
    /// Lane per row id. Missing means context (restored or mirrored rows).
    public private(set) var origins:          [UUID: QueueOrigin] = [:]
    public private(set) var currentIndex:     Int         = -1 { didSet { currentIndexSubject.send(currentIndex) } }
    public private(set) var shuffleEnabled:   Bool        = false { didSet { shuffleEnabledSubject.send(shuffleEnabled) } }
    public private(set) var repeatMode:       RepeatMode  = .off { didSet { repeatModeSubject.send(repeatMode) } }
    /// Last row of the "Repeat queue" group. Songs queued after repeat was turned
    /// on play after the loop. Held by row id so drags work. Nil unless `.all`.
    public private(set) var repeatBoundaryID: UUID?       = nil
    /// The list this session came from.
    public private(set) var source:           QueueSource = .none

    /// `$queue` and friends for Combine users; `@Observable` has no projections. Sent after the set.
    public var queuePublisher: AnyPublisher<[Track], Never> { queueSubject.eraseToAnyPublisher() }
    public var currentIndexPublisher: AnyPublisher<Int, Never> { currentIndexSubject.eraseToAnyPublisher() }
    public var shuffleEnabledPublisher: AnyPublisher<Bool, Never> { shuffleEnabledSubject.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { repeatModeSubject.eraseToAnyPublisher() }
    @ObservationIgnored private let queueSubject = CurrentValueSubject<[Track], Never>([])
    @ObservationIgnored private let currentIndexSubject = CurrentValueSubject<Int, Never>(-1)
    @ObservationIgnored private let shuffleEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let repeatModeSubject = CurrentValueSubject<RepeatMode, Never>(.off)

    /// The playlist playback started from, or nil.
    public var sourcePlaylistID: UUID? { source.playlistID }

    /// Whether a playlist has sides. Set by AppDependencies.
    @ObservationIgnored public var playlistLookup: (UUID) -> Playlist? = { _ in nil }

    /// Repeat all on a playlist with sides: the tape flips from side to side.
    public var isAutoReverse: Bool {
        repeatMode == .all && sourcePlaylistID.flatMap(playlistLookup)?.sideLayout.isEmpty == false
    }

    /// Side titles by row id: the playing row's side and each context row that starts
    /// a new one. Empty unless a playlist with sides plays in running order.
    public func sideMarks() -> [UUID: String] {
        guard let playlist = sourcePlaylistID.flatMap(playlistLookup) else { return [:] }
        let layout = playlist.sideLayout
        guard !layout.isEmpty else { return [:] }
        let numbers = playlist.sideNumbers()
        var marks: [UUID: String] = [:]
        var last: Int?
        for (i, row) in entries.enumerated() where row.origin == .context {
            guard let side = numbers[row.track.id] else { continue }
            // Shuffled or sorted, so sides mean nothing.
            if let last, side < last { return [:] }
            if side != last || i == currentIndex {
                let name = layout[side].side.name
                marks[row.id] = "Side \(PlaylistSide.letter(side))" + (name.isEmpty ? "" : " \u{00B7} \(name)")
            }
            last = side
        }
        return marks
    }

    /// The repeat divider's text. Auto-reverse names the side the tape flips to.
    public var repeatDividerLabel: String {
        guard isAutoReverse else { return "Repeats from here" }
        return "Flips to " + (entryIDs.first.flatMap { sideMarks()[$0] } ?? "Side A")
    }

    public var repeatLabel: String {
        isAutoReverse ? "Auto-reverse" : repeatMode.accessibilityLabel
    }

    public var repeatSystemImage: String {
        isAutoReverse ? "arrow.left.arrow.right" : repeatMode.systemImage
    }

    /// Boundary position in the current queue. Nil when repeat isn't `.all` or the
    /// row is gone; callers treat nil as the whole queue.
    public var repeatBoundaryIndex: Int? {
        guard repeatMode == .all, let id = repeatBoundaryID else { return nil }
        return entryIDs.firstIndex(of: id)
    }

    /// Rows below the boundary, which play once repeat is off.
    public func isAfterRepeatGroup(index: Int) -> Bool {
        guard let boundary = repeatBoundaryIndex else { return false }
        return index > boundary
    }

    // MARK: - Private

    /// The context lane's unshuffled order as row ids. Stale ids are pruned lazily.
    @ObservationIgnored private var contextOrderIDs: [UUID] = []

    // MARK: - Derived

    /// A queue row with its own id and position. Lists key off this, never the track id.
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

    /// Untagged rows are context.
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

    /// A block of the upcoming queue with its heading. Derived on read so the Mac
    /// panel and iOS sheet can't drift.
    public struct Section: Identifiable, Sendable {
        public let origin: QueueOrigin
        public let title:  String
        public let rows:   [Entry]
        public var id: QueueOrigin { origin }
    }

    /// Everything after the playing row, or the whole queue if nothing's playing yet.
    public var upcomingRows: [Entry] {
        let rows  = entries
        let start = currentIndex + 1
        guard start < rows.count else { return [] }
        return Array(rows[start...])
    }

    /// Upcoming rows split into non-empty lanes.
    public var upcomingSections: [Section] {
        let rows = upcomingRows
        guard !rows.isEmpty else { return [] }
        return [QueueOrigin.manual, .context, .recommendation].compactMap { lane in
            let laneRows = rows.filter { $0.origin == lane }
            guard !laneRows.isEmpty else { return nil }
            return Section(origin: lane, title: title(for: lane), rows: laneRows)
        }
    }

    /// Section heading for a lane: "Next in queue", "Next up: <list>", "Next up:
    /// recommended songs". The bare fallback is for queues with no source list.
    public func title(for lane: QueueOrigin) -> String {
        switch lane {
        case .manual:         return "Next in queue"
        case .context:        return source.displayName.map { "Next up: \($0)" } ?? "Next up"
        case .recommendation: return "Next up: recommended songs"
        }
    }

    /// Context rows still ahead. Suggestions only top up when this hits zero.
    public var remainingContextCount: Int { upcomingSlots(in: .context).count }

    /// Recommendation rows ahead, the depth the suggestion service maintains.
    public var remainingRecommendationCount: Int { upcomingSlots(in: .recommendation).count }

    // MARK: - Queue Loading

    /// Replaces the queue with `tracks`, all context, starting at `track`. Resets
    /// the source; callers name it via `setSource(_:)`. `startIndex` picks a specific
    /// row (e.g. the second copy of a song); nil searches for the song.
    public func play(track: Track, in tracks: [Track], startIndex: Int? = nil) {
        source = .none
        // Manually queued songs survive: they're re-inserted at the head of the new queue.
        alignEntryIDs()
        let carriedManual = upcomingSlots(in: .manual).map { queue[$0] }
        // A new list is a new session; an earlier "clear queue" doesn't carry.
        autoQueuePausedForID = nil
        // Find the clicked row. Never fall back to a different song; if it's missing,
        // the clicked track goes into the queue itself.
        var list  = tracks
        var start = 0
        if let index = startIndex, tracks.indices.contains(index) {
            start = index
        } else if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            start = index
        } else if let index = tracks.firstIndex(where: { Self.isSameSong($0, track) }) {
            // Same song under a different id (re-import, rebuilt list).
            start = index
        } else {
            list  = [track] + tracks
            start = 0
        }

        let ids = list.map { _ in UUID() }
        origins         = Dictionary(uniqueKeysWithValues: ids.map { ($0, QueueOrigin.context) })
        contextOrderIDs = ids
        if shuffleEnabled, !list.isEmpty {
            // Shuffle on: the clicked song leads and the whole rest of the list is
            // shuffled, not just what's after it.
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

    /// "Clear added songs": drops only the manual lane. Counterpart to `clearUpcoming`.
    public func clearManualQueue() {
        alignEntryIDs()
        let drop = Set(upcomingSlots(in: .manual))
        guard !drop.isEmpty else { return }
        // Assigned once, for the same reason as `reorderUpcoming`.
        queue = queue.indices.filter { !drop.contains($0) }.map { queue[$0] }
        entryIDs = entryIDs.indices.filter { !drop.contains($0) }.map { entryIDs[$0] }
        pruneToLiveRows()
    }

    public var hasManualQueue: Bool { !upcomingSlots(in: .manual).isEmpty }

    /// Same song by title and artist; other fields can differ.
    private static func isSameSong(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedSame
        && lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
    }

    /// Empties the queue, used when the playing track is deleted from the library.
    public func clearCurrentTrack() {
        queue                = []
        entryIDs             = []
        origins              = [:]
        contextOrderIDs      = []
        smartRowIDs          = []
        currentIndex         = -1
        source               = .none
        repeatBoundaryID     = nil
        autoQueuePausedForID = nil
    }

    /// Name the list this playback session came from.
    public func setSource(_ source: QueueSource) {
        self.source = source
    }

    /// Mirrors an online Discover session into the queue for display only.
    /// OnlinePlaybackCoordinator drives playback, so this doesn't touch shuffle, repeat
    /// or loading. `index` is -1 when nothing has started. `lanes` is the
    /// coordinator's per-slot lane record.
    public func setOnlineDisplayQueue(_ tracks: [Track],
                                      currentIndex index: Int,
                                      lanes: [QueueOrigin] = [],
                                      source: QueueSource = .none) {
        // Reuse row ids where the order lines up, so an append doesn't rebuild every row.
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
        self.source     = source
    }

    // MARK: - Session Snapshot

    /// A saveable queue for relaunch. Stores track ids, not tracks (no artwork in
    /// UserDefaults). Row ids are minted fresh on restore.
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

    /// Rebuilds a saved queue from the library (keyed by id), dropping deleted
    /// songs. Returns the playing track, or nil if nothing is left.
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
        // If the playing song was deleted, start at the top.
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

    /// Single-track queue for resume-on-launch. Leaves shuffle and repeat alone.
    public func restoreSession(track: Track) {
        let id          = UUID()
        origins         = [id: .context]
        contextOrderIDs = [id]
        queue           = [track]
        entryIDs        = [id]
        currentIndex    = 0
        // A mirrored or restored song isn't playing from the old list.
        source          = .none
    }

    // MARK: - Navigation

    /// What `advance()` would return, without mutating. Used for crossfade preload.
    public func peekNext() -> Track? {
        guard !queue.isEmpty else { return nil }
        // Nothing started yet: the first row is next (avoids `queue[-1]` for `.one`).
        guard currentIndex >= 0 else { return queue[0] }
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
        guard currentIndex >= 0 else { currentIndex = 0; return queue[0] }
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
        // Nothing started yet: no previous.
        guard !queue.isEmpty, currentIndex >= 0 else { return nil }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            // Wrap to the end of the repeat group, not the queue.
            currentIndex = repeatBoundaryIndex ?? queue.count - 1
        }
        return queue[currentIndex]
    }

    // MARK: - Queue Editing

    /// Set while this device is a Jam guest: "Add to Queue" and "Play Next" go to
    /// the host's queue instead (returns true when it took them).
    @ObservationIgnored public var manualRedirect: (([Track]) -> Bool)?

    /// Where a new row of `lane` goes to keep lanes in order, e.g. "Add to Queue"
    /// lands after the other manual rows, not behind the whole playlist.
    private func insertionIndex(for lane: QueueOrigin) -> Int {
        let start = max(currentIndex + 1, 0)
        var i = min(start, queue.count)
        while i < queue.count, origin(at: i) <= lane { i += 1 }
        return i
    }

    /// "Play Next": plays before anything else waiting.
    public func insertNext(_ track: Track, manual: Bool = true) {
        insertNext(contentsOf: [track], manual: manual)
    }

    /// A whole album or mix next, in its running order, as one change.
    public func insertNext(contentsOf tracks: [Track], manual: Bool = true) {
        if manual, manualRedirect?(tracks) == true { return }
        insert(tracks, at: min(max(currentIndex + 1, 0), queue.count),
               lane: manual ? .manual : .context)
    }

    /// "Add to Queue": after other manual rows, before the playlist. Duplicates allowed.
    public func append(_ track: Track, manual: Bool = true) {
        append(contentsOf: [track], manual: manual)
    }

    /// Appends many as one change so the queue republishes once.
    public func append(contentsOf tracks: [Track], manual: Bool = true) {
        append(contentsOf: tracks, lane: manual ? .manual : .recommendation)
    }

    /// Add rows to a specific lane, in the one place that lane's rows belong.
    public func append(contentsOf tracks: [Track], lane: QueueOrigin) {
        guard !tracks.isEmpty else { return }
        if lane == .manual, manualRedirect?(tracks) == true { return }
        insert(tracks, at: insertionIndex(for: lane), lane: lane)
    }

    /// Splices rows in at `index`, tags them, and updates the context order.
    private func insert(_ tracks: [Track], at index: Int, lane: QueueOrigin) {
        guard !tracks.isEmpty else { return }
        alignEntryIDs()
        let at  = min(max(index, 0), queue.count)
        let ids = tracks.map { _ in UUID() }
        queue.insert(contentsOf: tracks, at: at)
        entryIDs.insert(contentsOf: ids, at: at)
        origins.merge(ids.map { ($0, lane) }) { $1 }
        // Context rows join the canonical order in place, so unshuffling keeps them there.
        if lane == .context {
            let before = entryIDs[..<at].filter { (origins[$0] ?? .context) == .context }
            let cut    = before.isEmpty ? 0
                       : (contextOrderIDs.firstIndex(of: before.last!).map { $0 + 1 } ?? contextOrderIDs.count)
            contextOrderIDs.insert(contentsOf: ids, at: min(cut, contextOrderIDs.count))
        }
    }

    /// Patches in artwork that arrived after queueing. Only fills empty slots unless `replacing`.
    public func fillArtwork(_ data: Data, forTrackID id: UUID, replacing: Bool = false) {
        for i in queue.indices where queue[i].id == id && (replacing || queue[i].artworkData == nil) {
            queue[i].artworkData = data
        }
    }

    /// The song playing when the queue was last cleared. Autoplay stays paused for
    /// it so the cleared queue isn't refilled; a new song resumes it.
    public private(set) var autoQueuePausedForID: UUID? = nil

    /// Stop the auto-queue topping the list up again until something else plays.
    public func pauseAutoQueue() { autoQueuePausedForID = currentTrack?.id }

    /// "Clear queue": drops everything after the playing song. With nothing
    /// playing, clears it all.
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

    /// Removes one row. Refuses the playing row.
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

    /// Moves a row, with SwiftUI `onMove` index semantics (`destination` is
    /// pre-removal and may equal `queue.count`). Rows dragged across a lane boundary
    /// take the new lane.
    public func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source) else { return }
        guard destination >= 0, destination <= queue.count else { return }
        // Moving an item onto itself (or to the slot just after itself) is a no-op.
        guard destination != source, destination != source + 1 else { return }

        alignEntryIDs()

        // By row id, since a song may be queued twice.
        let playingID = entryID(at: currentIndex)
        let moved     = queue[source]
        let movedID   = entryIDs[source]

        // `Array.move(fromOffsets:toOffset:)` is SwiftUI-only, so do it by hand.
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

    /// Gives a dropped row the lane of its neighbours: the row above (skipping the
    /// playing row), or at the very top the row below.
    private func retagAfterMove(rowID: UUID) {
        guard let index = entryIDs.firstIndex(of: rowID) else { return }
        guard index > currentIndex else {
            // Dropped above the playing song: treat as context.
            origins[rowID] = .context
            return
        }
        let above = index - 1 > currentIndex ? origin(at: index - 1) : nil
        let below = index + 1 < queue.count  ? origin(at: index + 1) : nil
        // At a boundary the row above wins; with nothing above, the one below.
        origins[rowID] = above ?? below ?? .manual
    }

    // MARK: - Shuffle

    /// Shuffles the context lane in place (or recommendations once context is
    /// spent). Manual rows never move.
    public func toggleShuffle() {
        setShuffle(!shuffleEnabled)
    }

    /// Sets shuffle explicitly. A list header's "always shuffle" must set it, not toggle.
    public func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        alignEntryIDs()
        if shuffleEnabled { reshuffleContext() } else { removeSmartRows(); restoreContextOrder() }
    }

    /// Reorder the upcoming context rows at random, in place.
    func reshuffleContext() {
        reorderUpcoming(in: shuffleLane) { $0.shuffled() }
    }

    /// Context, or recommendations once only those are left.
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

    // MARK: - Smart shuffle

    /// Rows smart shuffle mixed in. Tagged `.context` so they sit between the
    /// list's songs; tracked so turning it off removes exactly these.
    public private(set) var smartRowIDs: Set<UUID> = []

    /// Mix `tracks` in, one after every `every` of the list's own upcoming rows.
    public func interleaveSmart(_ tracks: [Track], every: Int = 4) {
        guard !tracks.isEmpty, every > 0 else { return }
        alignEntryIDs()
        var pool = tracks
        var run  = 0
        var i    = max(currentIndex + 1, 0)
        while i < queue.count, !pool.isEmpty {
            defer { i += 1 }
            guard origin(at: i) == .context, !smartRowIDs.contains(entryIDs[i]) else { continue }
            run += 1
            guard run == every else { continue }
            run = 0
            insert([pool.removeFirst()], at: i + 1, lane: .context)
            if let id = entryID(at: i + 1) { smartRowIDs.insert(id) }
            i += 1   // step over the row just inserted
        }
    }

    /// Take the mixed-in rows back out, leaving the list exactly as it was.
    public func removeSmartRows() {
        guard !smartRowIDs.isEmpty else { return }
        alignEntryIDs()
        // `remove(at:)` skips the playing row and prunes `smartRowIDs`.
        for slot in entryIDs.indices.reversed() where smartRowIDs.contains(entryIDs[slot]) {
            remove(at: slot)
        }
    }

    /// The upcoming rows belonging to `lane`, as queue positions.
    private func upcomingSlots(in lane: QueueOrigin) -> [Int] {
        let start = max(currentIndex + 1, 0)
        guard start < queue.count else { return [] }
        return (start..<queue.count).filter { origin(at: $0) == lane }
    }

    /// Transforms the ids of `lane`'s upcoming rows and writes them back into the same slots.
    private func reorderUpcoming(in lane: QueueOrigin, _ transform: ([UUID]) -> [UUID]) {
        let slots = upcomingSlots(in: lane)
        guard slots.count > 1 else { return }

        let byID    = Dictionary(uniqueKeysWithValues: slots.map { (entryIDs[$0], queue[$0]) })
        let ordered = transform(slots.map { entryIDs[$0] })
        // Copied and assigned once: each element write publishes, and every subscriber rebuilt
        // the whole queue per write. Shuffling 2,000 songs froze the app for 9 s.
        var ids = entryIDs, rows = queue
        for (slot, id) in zip(slots, ordered) {
            ids[slot] = id
            if let track = byID[id] { rows[slot] = track }
        }
        entryIDs = ids
        queue = rows
    }

    // MARK: - Repeat

    public func cycleRepeat() {
        setRepeat(repeatMode.next)
    }

    /// Sets repeat mode. `.all` fixes the group at what's queued now.
    public func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        repeatBoundaryID = mode == .all ? entryIDs.last : nil
    }

    /// Moves the repeat group's end to `rowID`. Ignores unknown ids.
    public func setRepeatBoundary(rowID: UUID?) {
        guard repeatMode == .all else { return }
        guard let rowID else { repeatBoundaryID = entryIDs.last; return }
        guard entryIDs.contains(rowID) else { return }
        repeatBoundaryID = rowID
    }

    // MARK: - Private

    /// Drops tags and order entries for rows no longer queued.
    private func pruneToLiveRows() {
        let live = Set(entryIDs)
        origins  = origins.filter { live.contains($0.key) }
        contextOrderIDs.removeAll { !live.contains($0) }
        if !smartRowIDs.isSubset(of: live) { smartRowIDs.formIntersection(live) }
    }

    /// Syncs the canonical context order after a drag. Shuffle off: queue order
    /// becomes canonical. Shuffle on: keep the remembered order but fix membership,
    /// adding rows that joined the lane and dropping ones that left.
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
            // Insert after the preceding context row, not at the end.
            let after = contextIDs[..<i].last { contextOrderIDs.contains($0) }
            let at    = after.flatMap { contextOrderIDs.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            contextOrderIDs.insert(id, at: min(at, contextOrderIDs.count))
        }
    }

    /// Row ids for a replacement queue, reusing existing ids where order matches.
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

    /// Repairs `entryIDs` if it ever drifts from `queue`.
    private func alignEntryIDs() {
        guard entryIDs.count != queue.count else { return }
        if entryIDs.count > queue.count {
            entryIDs.removeLast(entryIDs.count - queue.count)
        } else {
            entryIDs.append(contentsOf: (0..<(queue.count - entryIDs.count)).map { _ in UUID() })
        }
    }

    /// Read-only version of `alignEntryIDs()`.
    private func alignedEntryIDs() -> [UUID] {
        guard entryIDs.count != queue.count else { return entryIDs }
        var ids = Array(entryIDs.prefix(queue.count))
        while ids.count < queue.count { ids.append(UUID()) }
        return ids
    }
}
