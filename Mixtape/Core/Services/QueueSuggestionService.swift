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
    private let targetAhead = 10
    /// Replenish once upcoming drops to this few.
    private let lowWatermark = 5

    // MARK: - Dependencies

    private unowned let queue:       QueueService
    private unowned let engine:      PlaybackEngine
    private unowned let library:     LibraryService
    private let itunes:      ITunesSearchClient
    private weak  var coordinator: OnlinePlaybackCoordinator?

    private var cancellables = Set<AnyCancellable>()
    private var isReplenishing = false
    /// Online suggestions whose yt-dlp download is still in flight. Counted toward
    /// the queue depth so we don't keep re-triggering (and spiralling) while they
    /// land asynchronously.
    private var inFlight = 0

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

    /// True when we should auto-fill: the user is playing songs that aren't a
    /// curated user playlist (Songs / album / artist / All Songs / Favourites),
    /// the queue is running low, and it isn't on repeat. Runs regardless of
    /// shuffle so the queue always shows what plays next.
    ///
    /// A *user* playlist shows its own tracks — no suggestions are added.
    private var shouldReplenish: Bool {
        guard !isReplenishing else { return false }
        guard queue.currentTrack != nil else { return false }   // nothing playing
        guard !isUserPlaylistSource else { return false }       // user playlists show their own tracks
        guard queue.repeatMode == .off else { return false }    // repeat handles continuity
        // Online Discover only auto-recommends when shuffle is on; with shuffle
        // off the user plays the search results straight through.
        if engine.hasOnlineContext && !queue.shuffleEnabled { return false }
        return pendingDepth <= lowWatermark
    }

    /// Upcoming tracks already queued plus online ones still downloading.
    private var pendingDepth: Int { upcomingCount + inFlight }

    /// Whether playback originated from a user-created playlist (as opposed to
    /// the general library, an album, an artist, or the system playlists).
    private var isUserPlaylistSource: Bool {
        guard let id = queue.sourcePlaylistID else { return false }
        return id != Playlist.allSongsID && id != Playlist.favouritesID
    }

    private var upcomingCount: Int {
        max(0, queue.queue.count - 1 - queue.currentIndex)
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

        // Online Discover session: navigation flows through the coordinator's
        // context (each track downloaded on demand), not the local queue. Extend
        // it with Deezer "artist radio" picks similar to the current track —
        // local-library tracks don't fit the online navigation model.
        if engine.hasOnlineContext {
            let picks = Array(await deezerSuggestions(for: seed, excluding: seen).prefix(need))
            coordinator?.appendOnlineSuggestions(picks)
            return
        }

        var localPool  = localSuggestions(for: seed, excluding: seen)
        var deezerPool = await deezerSuggestions(for: seed, excluding: seen)

        // Pick `need` suggestions as a random local/Deezer mix. Locals are
        // appended instantly; Deezer picks are collected and downloaded
        // concurrently afterwards so a slow yt-dlp fetch never stalls the fill.
        var onlinePicks: [OnlineTrack] = []
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
                queue.append(track)          // instant
            }
            added += 1
        }

        // Download + append the Deezer picks concurrently in the background.
        // `inFlight` keeps them counted toward queue depth until they land so we
        // don't re-trigger and spiral while they download.
        guard let coordinator, !onlinePicks.isEmpty else { return }
        inFlight += onlinePicks.count
        for online in onlinePicks {
            Task { [weak self] in
                await coordinator.addToQueue(online)
                self?.inFlight -= 1
            }
        }
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
        let radio = await itunes.radioTracks(forArtist: seed.artistName, limit: 20)
        return radio.filter { !seen.contains(Self.key(forTitle: $0.title, artist: $0.artistName)) }
                    .shuffled()
    }

    // MARK: - Dedup keys

    private static func key(_ t: Track) -> String { key(forTitle: t.title, artist: t.artistName) }
    private static func key(forTitle title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }
}
