// Tops up the queue with similar songs once the playlist runs out: library
// matches (same artist/genre) and Deezer artist radio, never jumping scenes.

import Foundation
import Combine

@MainActor
public final class QueueSuggestionService: ObservableObject {

    // MARK: - Tuning

    /// Upcoming tracks to keep queued once recommendations take over.
    private let targetAhead = 30
    /// Replenish once upcoming drops to this few.
    private let lowWatermark = 10

    // MARK: - Dependencies

    private unowned let queue:       QueueService
    private unowned let engine:      PlaybackEngine
    private unowned let library:     LibraryService
    private let itunes:      ITunesSearchClient
    private weak  var coordinator: OnlinePlaybackCoordinator?

    private var cancellables = Set<AnyCancellable>()
    private var isReplenishing = false

    // MARK: - Init

    public init(queue: QueueService,
                engine: PlaybackEngine,
                library: LibraryService,
                itunes: ITunesSearchClient,
                coordinator: OnlinePlaybackCoordinator) {
        self.queue       = queue
        self.engine      = engine
        self.library     = library
        self.itunes      = itunes
        self.coordinator = coordinator

        // React whenever the current track or the queue contents change.
        queue.$currentIndex
            .sink { [weak self] _ in self?.scheduleReplenishIfNeeded() }
            .store(in: &cancellables)
        queue.$queue
            .sink { [weak self] _ in self?.scheduleReplenishIfNeeded() }
            .store(in: &cancellables)

        // Only listens for switch-on; `setShuffle` removes the picks on switch-off.
        queue.$shuffleEnabled
            .removeDuplicates()
            .sink { [weak self] on in
                guard on else { return }
                // Next tick, so `setShuffle`'s reshuffle doesn't scatter them.
                Task { self?.mixInSmartPicks() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Trigger

    private func scheduleReplenishIfNeeded() {
        guard shouldReplenish else { return }
        Task {
            // Let state settle; Discover installs its context handler just after `engine.play()`.
            try? await Task.sleep(for: .milliseconds(400))
            guard shouldReplenish else { return }
            await replenish()
        }
    }

    /// Top up once the context lane is empty, not at a low-water mark. Shuffle
    /// doesn't suppress it; repeat does.
    private var shouldReplenish: Bool {
        guard Self.autoplayEnabled else { return false }
        guard !isReplenishing else { return false }
        guard let playing = queue.currentTrack else { return false }   // nothing playing
        // The user cleared the queue while this song was playing: don't undo it.
        guard queue.autoQueuePausedForID != playing.id else { return false }
        guard queue.repeatMode == .off else { return false }     // repeat handles continuity
        guard queue.remainingContextCount == 0 else { return false }  // the chosen list is still going
        return pendingDepth <= lowWatermark
    }

    private var pendingDepth: Int { queue.remainingRecommendationCount }

    /// Settings > Playback > Smart Shuffle. Opt-in.
    public static var smartShuffleEnabled: Bool {
        UserDefaults.standard.bool(forKey: "playback.smartShuffle")
    }

    /// One mixed-in song after every this many of the list's own.
    private let smartEvery = 4

    // MARK: - Smart shuffle

    /// Mixes library songs not in this list into the shuffle. Library only, since
    /// they play without resolving.
    /// ponytail: Deezer picks need the coordinator's device id and artwork prefetch
    /// made public; add if the library is too thin.
    private func mixInSmartPicks() {
        guard Self.smartShuffleEnabled, queue.shuffleEnabled, !engine.hasOnlineContext else { return }
        guard let seed = queue.currentTrack else { return }
        let ahead = queue.remainingContextCount
        guard ahead >= smartEvery else { return }   // too short a run to mix into
        let seen  = Set(queue.queue.map(Self.key))
        let picks = Array(localSuggestions(for: seed, excluding: seen).prefix(ahead / smartEvery))
        guard !picks.isEmpty else { return }
        queue.interleaveSmart(picks, every: smartEvery)
    }

    /// Settings > Playback > Autoplay. On by default.
    public static var autoplayEnabled: Bool {
        UserDefaults.standard.object(forKey: "playback.autoplay") as? Bool ?? true
    }

    // MARK: - Replenish

    private func replenish() async {
        guard let seed = queue.currentTrack else { return }
        isReplenishing = true
        defer { isReplenishing = false }

        let need = targetAhead - pendingDepth
        guard need > 0 else { return }

        // Keys already present so we never queue a duplicate.
        var seen = Set(queue.queue.map(Self.key))

        // Online session: extend the coordinator's context with Deezer radio picks.
        if engine.hasOnlineContext {
            let picks = Array(await deezerSuggestions(for: seed, excluding: seen).prefix(need))
            // Repeat may have been turned on during the search.
            guard queue.repeatMode == .off else { return }
            coordinator?.appendOnlineSuggestions(picks)
            return
        }

        var localPool  = localSuggestions(for: seed, excluding: seen)
        var deezerPool = await deezerSuggestions(for: seed, excluding: seen)

        // Random local/Deezer mix, appended per side in one go so the queue doesn't churn.
        var onlinePicks: [OnlineTrack] = []
        var localPicks:  [Track]       = []
        var added = 0
        while added < need, !(localPool.isEmpty && deezerPool.isEmpty) {
            let pickDeezer = !deezerPool.isEmpty && (localPool.isEmpty || Bool.random())
            if pickDeezer {
                let online = deezerPool.removeFirst()
                guard seen.insert(Self.key(forTitle: online.title, artist: online.artistName)).inserted else { continue }
                onlinePicks.append(online)
            } else {
                let track = localPool.removeFirst()
                guard seen.insert(Self.key(track)).inserted else { continue }
                // Recommendation lane: below manual and context rows.
                localPicks.append(track)
            }
            added += 1
        }

        // The search took time; repeat may have been switched on while it ran.
        guard queue.repeatMode == .off else { return }
        if !localPicks.isEmpty { queue.append(contentsOf: localPicks, lane: .recommendation) }

        // One append. Rows resolve when reached, so there's no need to download first.
        guard let coordinator, !onlinePicks.isEmpty else { return }
        await coordinator.addToQueue(onlinePicks, lane: .recommendation)
    }

    // MARK: - Local suggestions

    /// Library tracks like `seed`: same artist, then same genre, shuffled per tier.
    private func localSuggestions(for seed: Track, excluding seen: Set<String>) -> [Track] {
        let pool = library.tracks.filter { t in
            t.id != seed.id && !seen.contains(Self.key(t)) && SuggestionFeedback.allows(t)
        }

        let seedGenre  = seed.genre?.lowercased()
        let seedArtist = seed.artistName.lowercased()

        let sameGenre  = seedGenre.map { g in
            pool.filter { ($0.genre?.lowercased() ?? "") == g }
        } ?? []
        let sameArtist = pool.filter { $0.artistName.lowercased() == seedArtist }

        // No genre and no same-artist tracks: suggest nothing rather than jump genres.
        var ordered: [Track] = []
        var added = Set<Track.ID>()
        for t in sameArtist.shuffled() + sameGenre.shuffled() where added.insert(t.id).inserted {
            ordered.append(t)
        }
        return ordered
    }

    // MARK: - Deezer suggestions

    private func deezerSuggestions(for seed: Track, excluding seen: Set<String>) async -> [OnlineTrack] {
        let radio = await itunes.deepRadioTracks(forArtist: seed.artistName, limit: targetAhead + 20)
        return radio.filter { !seen.contains(Self.key(forTitle: $0.title, artist: $0.artistName)) }
                    .shuffled()
    }

    // MARK: - Dedup keys

    // `identityTitle` so a library row with a feature credit matches the bare
    // catalogue title and isn't suggested twice.
    private static func key(_ t: Track) -> String { key(forTitle: t.identityTitle, artist: t.artistName) }
    private static func key(forTitle title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }
}
