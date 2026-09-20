// QueueSuggestionService.swift
// Mixtape
//
// Tops up the queue before it runs dry (no repeat, nearly exhausted) with songs
// similar to the current track — a mix of local-library matches and Deezer artist
// radio. Local picks share the track's genre/artist and radio comes from the seed
// artist, so nothing jumps scenes (rap → classical). Appended like normal tracks.

import Foundation
import Combine

@MainActor
public final class QueueSuggestionService: ObservableObject {

    // MARK: - Tuning

    /// Keep at least this many upcoming tracks queued ahead of the current one.
    /// A recommended run should feel like a station, not like three bonus songs.
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
    }

    // MARK: - Trigger

    private func scheduleReplenishIfNeeded() {
        guard shouldReplenish else { return }
        Task {
            // Let transient state settle — e.g. Discover installs its online
            // context handler just after engine.play(), so a same-tick check
            // could mistake an online track for a local-queue session.
            try? await Task.sleep(for: .milliseconds(400))
            guard shouldReplenish else { return }
            await replenish()
        }
    }

    /// True when we should top the queue up with recommendations.
    ///
    /// The rule is the one every other player uses: recommendations start where
    /// the list the user chose *ends*. So this waits for the context lane to run
    /// out entirely rather than firing at a low-water mark — a "Next up:
    /// recommended songs" heading appearing while five songs of the playlist are
    /// still queued is the app talking over the user.
    ///
    /// Shuffle doesn't suppress it: a shuffled playlist still reaches its end,
    /// and the answer there is the same as the unshuffled one — keep the music
    /// going with songs like it. Repeat does suppress it, because repeat is
    /// already an answer to "what plays after the last song".
    private var shouldReplenish: Bool {
        guard !isReplenishing else { return false }
        guard let playing = queue.currentTrack else { return false }   // nothing playing
        // The user cleared the queue while this song was playing: don't undo it.
        guard queue.autoQueuePausedForID != playing.id else { return false }
        guard queue.repeatMode == .off else { return false }     // repeat handles continuity
        guard queue.remainingContextCount == 0 else { return false }  // the chosen list is still going
        return pendingDepth <= lowWatermark
    }

    private var pendingDepth: Int { queue.remainingRecommendationCount }

    // MARK: - Replenish

    private func replenish() async {
        guard let seed = queue.currentTrack else { return }
        isReplenishing = true
        defer { isReplenishing = false }

        let need = targetAhead - pendingDepth
        guard need > 0 else { return }

        // Keys already present so we never queue a duplicate.
        var seen = Set(queue.queue.map(Self.key))

        // Online Discover session: navigation flows through the coordinator's
        // context (each track downloaded on demand), not the local queue. Extend
        // it with Deezer "artist radio" picks similar to the current track —
        // local-library tracks don't fit the online navigation model.
        if engine.hasOnlineContext {
            let picks = Array(await deezerSuggestions(for: seed, excluding: seen).prefix(need))
            // The search took time, and repeat may have been switched on
            // while it ran.
            guard queue.repeatMode == .off else { return }
            coordinator?.appendOnlineSuggestions(picks)
            return
        }

        var localPool  = localSuggestions(for: seed, excluding: seen)
        var deezerPool = await deezerSuggestions(for: seed, excluding: seen)

        // Pick `need` suggestions as a random local/Deezer mix, then append
        // each side in one go — a per-song append republishes the queue per
        // song, which is what made a fill look like the queue reshuffling.
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
                // The recommendation lane: nobody asked for this one, it is the
                // top-up, and it sorts below both the user's own queued songs
                // and whatever is left of the list they were playing.
                localPicks.append(track)
            }
            added += 1
        }

        // The search took time; repeat may have been switched on while it ran.
        guard queue.repeatMode == .off else { return }
        if !localPicks.isEmpty { queue.append(contentsOf: localPicks, lane: .recommendation) }

        // One append, not one per download. Each pick used to be downloaded
        // first and appended as it landed, so the queue rewrote itself a dozen
        // times over the following minute — the songs sitting after the current
        // one kept changing under the user. A queued row needs no file (it is
        // resolved when the queue reaches it), so they all land at once and stay
        // put.
        guard let coordinator, !onlinePicks.isEmpty else { return }
        await coordinator.addToQueue(onlinePicks, lane: .recommendation)
    }

    // MARK: - Local suggestions

    /// Library tracks similar to `seed`, genre-coherent: same genre first, then
    /// same artist, shuffled within each tier. Never random across genres.
    private func localSuggestions(for seed: Track, excluding seen: Set<String>) -> [Track] {
        let pool = library.tracks.filter { t in
            t.id != seed.id && !seen.contains(Self.key(t))
        }

        let seedGenre  = seed.genre?.lowercased()
        let seedArtist = seed.artistName.lowercased()

        let sameGenre  = seedGenre.map { g in
            pool.filter { ($0.genre?.lowercased() ?? "") == g }
        } ?? []
        let sameArtist = pool.filter { $0.artistName.lowercased() == seedArtist }

        // Same artist is the strongest similarity signal, then same genre.
        // If the seed has no genre and no same-artist tracks, suggest nothing
        // locally rather than risk an incoherent cross-genre pick.
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

    // `identityTitle`, so a saved Discover song compares under the spelling the
    // catalogue uses: the library row prints the feature credit, the suggestion
    // coming back off the radio endpoint doesn't, and keying on the stored title
    // made those two look like different songs — so a song already in the queue
    // could be suggested straight back into it. An imported row has no key to
    // check the bare spelling against, so it still compares as stored.
    private static func key(_ t: Track) -> String { key(forTitle: t.identityTitle, artist: t.artistName) }
    private static func key(forTitle title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }
}
