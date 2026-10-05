import Foundation
import Combine

/// Tape decks: three named queues you switch between, each keeping its song and position.
/// The live queue always belongs to the active deck; the others are parked snapshots. Per device,
/// like the resume-on-launch queue.
@MainActor
public final class TapeDeckService: ObservableObject {

    public struct Deck: Codable, Identifiable {
        public let id: Int
        public var name: String
        var snapshot: QueueService.Snapshot?
        var position: TimeInterval = 0
        /// Rows held for this launch, so Discover songs the library doesn't have survive a switch.
        var tracks: [Track] = []

        enum CodingKeys: String, CodingKey { case id, name, snapshot, position }
    }

    @Published public private(set) var decks: [Deck]
    @Published public private(set) var activeID: Int

    private let engine: PlaybackEngine
    private let coordinator: OnlinePlaybackCoordinator
    private let library: LibraryService
    private let toast: (Toast) -> Void
    private let addToPlaylist: ([UUID], UUID) -> Void
    private var isSwitching = false

    private static let key = "playback.tapeDecks"
    private struct Stored: Codable { var decks: [Deck]; var activeID: Int }

    init(engine: PlaybackEngine, coordinator: OnlinePlaybackCoordinator, library: LibraryService,
         toast: @escaping (Toast) -> Void, addToPlaylist: @escaping ([UUID], UUID) -> Void) {
        self.engine        = engine
        self.coordinator   = coordinator
        self.library       = library
        self.toast         = toast
        self.addToPlaylist = addToPlaylist
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        decks    = stored?.decks ?? Self.blank
        activeID = stored?.activeID ?? 0
    }

    private static var blank: [Deck] { (1...3).map { Deck(id: $0 - 1, name: "Deck \($0)") } }

    public var activeName: String { decks.first { $0.id == activeID }?.name ?? "" }

    /// Parks the live queue on the active deck and picks `id` up where it stopped, playing on if
    /// something was playing.
    public func switchTo(_ id: Int) async {
        guard !isSwitching, id != activeID,
              let target = decks.firstIndex(where: { $0.id == id }),
              let current = decks.firstIndex(where: { $0.id == activeID }) else { return }
        // Mirroring another device: that queue isn't ours to park.
        guard engine.remoteTransport == nil else {
            toast(.failed("Switch decks on the device that's playing"))
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        let queue = engine.queue
        let wasPlaying = engine.state == .playing
        decks[current].snapshot = queue.queue.isEmpty ? nil : queue.snapshot
        decks[current].position = engine.currentTime
        decks[current].tracks   = queue.queue
        activeID = id
        save()

        let deck = decks[target]
        var byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in deck.tracks where byID[track.id] == nil { byID[track.id] = track }
        coordinator.endSession()
        await engine.loadDeck(deck.snapshot, at: deck.position, from: byID, play: wasPlaying)
    }

    public func rename(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[i].name = String(trimmed.prefix(40))
        save()
    }

    /// "Save queue as playlist": the live deck's songs, saving any the library doesn't hold first.
    public func saveAsPlaylist(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for track in engine.queue.queue where seen.insert(track.id).inserted {
            if library.track(id: track.id) == nil { await coordinator.addToLibrary(unsaved: track) }
            // A save can keep an older row's id for the same song, so fall back to the name.
            guard let saved = library.track(id: track.id) ?? library.tracks.first(where: {
                $0.title.localizedCaseInsensitiveCompare(track.title) == .orderedSame
                    && $0.artistName.localizedCaseInsensitiveCompare(track.artistName) == .orderedSame
            }) else { continue }
            if saved.id != track.id, !seen.insert(saved.id).inserted { continue }
            ids.append(saved.id)
        }
        guard !ids.isEmpty else { return }
        let playlist = library.createPlaylist(name: trimmed)
        addToPlaylist(ids, playlist.id)
    }

    /// Sign-out and Clear Everything: the decks belong to the account that filled them.
    public func reset() {
        decks    = Self.blank
        activeID = 0
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(decks: decks, activeID: activeID)) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
