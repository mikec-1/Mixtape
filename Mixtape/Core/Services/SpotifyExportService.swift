// SpotifyExportService.swift
// Mixtape — Core/Services
//
// Sending music the other way: a Mixtape playlist recreated on Spotify, and
// Favourites pushed into Liked Songs.
//
// Why this is a one-shot and not a mirror
//   Coming *from* Spotify, every song arrives with a Spotify id, so a follow
//   check is exact. Going the other way there is no id to carry: a song ripped
//   from a file or found in Discover has only a title and an artist, and finding
//   it on Spotify is a search whose answer is sometimes a live version, a
//   karaoke cover, or nothing at all. A standing two-way sync would make those
//   guesses silently, over and over, with no moment at which anyone could look
//   at them. So this plans first, shows its work, and only writes what the user
//   has seen.
//
// The three verdicts
//   `confident`  — the normalised title and artist agree and the runtimes are
//                  within a few seconds. Ticked by default.
//   `uncertain`  — something came back, but not something this is willing to
//                  claim is the same recording. Shown, and *not* ticked.
//   `missing`    — Spotify has nothing under that name. Reported so the count
//                  at the end is honest about what didn't make it.
//
// Liked Songs is additive, always
//   `pushLikes` only ever adds. A song you unhearted here is not a song you
//   asked to unlike on Spotify, and a push that could remove things is a push
//   nobody would dare run twice.

import Foundation
import OSLog
import Combine

@MainActor
public final class SpotifyExportService: ObservableObject {

    // MARK: - Plan

    public struct Candidate: Identifiable, Sendable {

        public enum Verdict: Sendable, Equatable {
            case confident
            case uncertain
            case missing
            /// The lookup itself failed. Distinct from `missing` because "we
            /// couldn't ask" and "Spotify doesn't have it" are different facts,
            /// and printing the second when the first happened is a lie about
            /// the catalogue — which is exactly what a song with a hundred
            /// million streams reading "not on Spotify" was.
            ///
            /// It carries *why* so the wording can be true rather than vague:
            /// a rate limit is worth waiting out, a dead connection isn't.
            case unchecked(Reason)
        }

        /// Why a lookup produced no answer.
        public enum Reason: Sendable, Equatable {
            /// Spotify is throttling the app. Waiting fixes it; retrying now
            /// makes it worse. Carries Spotify's own advised wait when it gave
            /// one, because "try again later" and "try again in four minutes"
            /// are different amounts of help.
            case rateLimited(retryAfter: TimeInterval)
            /// Anything else — offline, a dropped connection, a bad reply.
            case unreachable

            public var sentence: String {
                switch self {
                case .rateLimited(let wait):
                    let when = wait >= 1
                        ? "try again in \(Self.phrase(wait))"
                        : "try again in a few minutes"
                    return "Spotify is limiting how often Mixtape can ask right now, \(when)"
                case .unreachable: return "Couldn't reach Spotify"
                }
            }

            private static func phrase(_ seconds: TimeInterval) -> String {
                let whole = max(1, Int(seconds.rounded()))
                guard whole >= 120 else { return "\(whole) second\(whole == 1 ? "" : "s")" }
                let minutes = Int((Double(whole) / 60).rounded())
                return "about \(minutes) minute\(minutes == 1 ? "" : "s")"
            }

            /// The same fact in a few words, for a list row.
            public var phrase: String {
                switch self {
                case .rateLimited: return "Spotify is rate-limiting, not checked"
                case .unreachable: return "Couldn't reach Spotify, not checked"
                }
            }
        }

        public let track: Track
        /// Best search result, when there was one.
        public let match: SpotifyTrackMatch?
        /// The runners-up, so someone can correct a bad guess in place.
        public let alternatives: [SpotifyTrackMatch]
        public let verdict: Verdict

        public var id: UUID { track.id }

        public var isUnchecked: Bool { uncheckedReason != nil }

        public var uncheckedReason: Reason? {
            if case .unchecked(let reason) = verdict { return reason }
            return nil
        }
    }

    public struct Plan: Sendable {
        public var name: String
        public var candidates: [Candidate]

        public var confident: [Candidate] { candidates.filter { $0.verdict == .confident } }
        public var uncertain: [Candidate] { candidates.filter { $0.verdict == .uncertain } }
        public var missing:   [Candidate] { candidates.filter { $0.verdict == .missing } }
        public var unchecked: [Candidate] { candidates.filter { $0.isUnchecked } }

        /// Why the unchecked ones went unchecked. A run stops at the first rate
        /// limit, so in practice every failure in one plan has the same cause.
        public var uncheckedReason: Candidate.Reason? {
            candidates.compactMap(\.uncheckedReason).first
        }
    }

    // MARK: - Published

    /// Songs looked up so far, out of how many, while a plan is being built.
    @Published public private(set) var planned: (done: Int, total: Int)?
    /// Songs written so far, out of how many, while a plan is being committed.
    @Published public private(set) var pushed: (done: Int, total: Int)?

    // MARK: - Dependencies

    private let client: SpotifyClient
    private let auth: SpotifyAuth
    private let defaults: UserDefaults

    public init(client: SpotifyClient, auth: SpotifyAuth, defaults: UserDefaults = .standard) {
        self.client   = client
        self.auth     = auth
        self.defaults = defaults
        loadMatchCache()
        loadMissCache()
    }

    // MARK: - Remembered matches

    /// A search result worth not asking for twice.
    ///
    /// Matching a favourite costs one Spotify search, and the review page runs
    /// the whole set every time it opens — nine hundred favourites is nine
    /// hundred searches on every visit, for answers that were the same last
    /// time. A recording's title, artist and length do not change, so once a
    /// song has been found it stays found.
    ///
    /// Only *found* songs are kept. A song Spotify had nothing for is looked up
    /// again next time: catalogues gain records, and caching an absence would
    /// hide a song from its owner permanently.
    private struct CachedMatch: Codable {
        var uri: String
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var confident: Bool

        var match: SpotifyTrackMatch {
            SpotifyTrackMatch(uri: uri, title: title, artist: artist,
                              album: album, duration: duration, coverURL: nil)
        }
    }

    /// A song Spotify had nothing for, and when we last asked.
    ///
    /// Misses used to be thrown away on the principle that catalogues gain
    /// records and a cached absence would hide a song from its owner forever.
    /// That principle is right and the implementation was the problem: a
    /// library with two thousand favourites, most of them unmatched, re-ran two
    /// thousand searches on every visit to the review page and spent the app's
    /// entire API quota doing it — after which *every* song reads as unfound,
    /// which hides far more than a stale miss ever would.
    ///
    /// So a miss is remembered, but it expires. Ask again after `missTTL` and
    /// the new record gets found; until then the page costs nothing.
    private struct CachedMiss: Codable {
        var checkedAt: Date
    }

    /// How long a "Spotify doesn't have this" answer is trusted before it is
    /// asked again. Long enough that repeated visits are free, short enough
    /// that a newly added record surfaces without anyone thinking about it.
    private static let missTTL: TimeInterval = 30 * 24 * 60 * 60

    private var matchCache: [String: CachedMatch] = [:]
    private var missCache:  [String: CachedMiss]  = [:]
    private static let matchCacheKey = "spotify.export.matchCache.v1"
    private static let missCacheKey  = "spotify.export.missCache.v1"

    private func loadMatchCache() {
        guard let data = defaults.data(forKey: Self.matchCacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedMatch].self, from: data)
        else { return }
        matchCache = decoded
    }

    private func loadMissCache() {
        guard let data = defaults.data(forKey: Self.missCacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedMiss].self, from: data)
        else { return }
        // Expired entries are dropped on the way in rather than checked on the
        // way out, so the store doesn't grow a tail of answers nobody trusts.
        let cutoff = Date().addingTimeInterval(-Self.missTTL)
        missCache = decoded.filter { $0.value.checkedAt > cutoff }
    }

    private func saveMissCache() {
        guard let data = try? JSONEncoder().encode(missCache) else { return }
        defaults.set(data, forKey: Self.missCacheKey)
    }

    /// True when this song was looked up recently and Spotify had nothing.
    /// `.unchecked` never lands here — a lookup that failed is not an answer.
    private func recentlyMissed(_ track: Track) -> Bool {
        guard let miss = missCache[track.id.uuidString] else { return false }
        return miss.checkedAt > Date().addingTimeInterval(-Self.missTTL)
    }

    private func saveMatchCache() {
        guard let data = try? JSONEncoder().encode(matchCache) else { return }
        defaults.set(data, forKey: Self.matchCacheKey)
    }

    private func remember(_ candidates: [Candidate]) {
        for candidate in candidates where candidate.verdict == .missing {
            missCache[candidate.track.id.uuidString] = CachedMiss(checkedAt: Date())
        }
        for candidate in candidates {
            guard let match = candidate.match, candidate.verdict != .missing else { continue }
            missCache.removeValue(forKey: candidate.track.id.uuidString)
            matchCache[candidate.track.id.uuidString] = CachedMatch(
                uri:       match.uri,
                title:     match.title,
                artist:    match.artist,
                album:     match.album,
                duration:  match.duration,
                confident: candidate.verdict == .confident
            )
        }
        saveMatchCache()
        saveMissCache()
    }

    /// Forgets every remembered match. The cache is keyed by local track id, so
    /// it means nothing to a different account.
    public func forgetMatches() {
        matchCache.removeAll()
        missCache.removeAll()
        defaults.removeObject(forKey: Self.matchCacheKey)
        defaults.removeObject(forKey: Self.missCacheKey)
    }

    public var canExport: Bool { auth.isAuthorized && auth.canWrite }

    // MARK: - Planning

    /// Looks every song up on Spotify and judges the results.
    ///
    /// Sequential, and not because it has to be: a hundred parallel searches
    /// would earn a 429 within seconds and finish slower than this does, and the
    /// progress it reports would be meaningless besides.
    public func plan(name: String, tracks: [Track]) async throws -> Plan {
        var token = try await auth.validAccessToken()
        let total = tracks.count
        planned = (0, total)
        defer { planned = nil }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(total)

        // Set the moment Spotify says we're over the limit. Everything after it
        // is recorded as unchecked without a request: once an app is being
        // throttled, grinding through another two thousand lookups deepens the
        // penalty and gets two thousand identical failures for it.
        var throttled = false
        var retryWait: TimeInterval = 0

        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()

            if throttled {
                candidates.append(Candidate(track: track, match: nil,
                                            alternatives: [],
                                            verdict: .unchecked(.rateLimited(retryAfter: retryWait))))
                planned = (index + 1, total)
                continue
            }

            // An answer we already have. `plan` is reached both from the export
            // sheet and from the favourites review, and the review runs the
            // whole favourites list, so consulting the cache here is what keeps
            // a second visit free.
            if let cached = matchCache[track.id.uuidString] {
                candidates.append(Candidate(track: track,
                                            match: cached.match,
                                            alternatives: [],
                                            verdict: cached.confident ? .confident : .uncertain))
                planned = (index + 1, total)
                continue
            }
            if recentlyMissed(track) {
                candidates.append(Candidate(track: track, match: nil,
                                            alternatives: [], verdict: .missing))
                planned = (index + 1, total)
                continue
            }

            // Re-asked as we go, not held for the whole run. A thousand songs is
            // longer than a Spotify token lives, and because a failed search is
            // swallowed below, an expired one wouldn't raise an error — it would
            // quietly report the second half of somebody's library as "not on
            // Spotify". `validAccessToken` is a keychain read until it isn't.
            if index > 0, index % 50 == 0 {
                token = (try? await auth.validAccessToken()) ?? token
            }

            // Deliberately not `try?`. A swallowed error here is indistinguishable
            // from an empty result set, and the sheet renders an empty result set
            // as "not on Spotify" — so one 429 used to relabel a song with a
            // hundred million streams as missing from the catalogue.
            do {
                let results = try await client.searchTracks(
                    title:  track.title,
                    artist: track.artistName,
                    accessToken: token
                )
                candidates.append(Self.judge(track: track, results: results))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var reason = Candidate.Reason.unreachable
                if case SpotifyPlaylistError.rateLimited(let wait) = error {
                    throttled = true
                    reason    = .rateLimited(retryAfter: wait)
                    retryWait = wait
                }
                candidates.append(Candidate(track: track, match: nil,
                                            alternatives: [], verdict: .unchecked(reason)))
            }
            planned = (index + 1, total)

            // The lookups are network-bound and already yield, but the judging
            // isn't — without this a long playlist would hold the main actor
            // between requests and stall the progress it's reporting.
            await Task.yield()
        }

        return Plan(name: name, candidates: candidates)
    }

    /// Picks a winner from a search result set, and says how sure it is.
    static func judge(track: Track, results: [SpotifyTrackMatch]) -> Candidate {
        guard let best = results.first else {
            return Candidate(track: track, match: nil, alternatives: [], verdict: .missing)
        }

        let wanted = LibraryTrackIndex.key(title: track.title, artistName: track.artistName)

        // Prefer a result whose identity key matches outright over merely the
        // one Spotify ranked first — relevance ranking answers "what did you
        // probably mean", which is not the same question.
        // The printed title carries the feature credit and the artist field
        // carries every guest; Spotify splits the same song the other way. Both
        // readings count as an exact name match, or every featured song would
        // come back "uncertain" for a difference in bookkeeping.
        let wantedCore = LibraryTrackIndex.key(
            title:      SpotifyClient.coreTitle(track.title),
            artistName: ImportService.primaryArtistName(from: track.artistName)
        )
        let exact = results.first {
            let full = LibraryTrackIndex.key(title: $0.title, artistName: $0.artist)
            let core = LibraryTrackIndex.key(
                title:      SpotifyClient.coreTitle($0.title),
                artistName: ImportService.primaryArtistName(from: $0.artist)
            )
            return full == wanted || core == wantedCore
        }
        let chosen = exact ?? best
        let alternatives = results.filter { $0.uri != chosen.uri }

        // A duration check on top of the name, because the commonest wrong
        // answer — a live take, an extended mix, a radio edit — has the right
        // name and the wrong length. Skipped when the library row never learned
        // its own duration, where it would fail everything for no reason.
        let sameLength = track.duration <= 0
            || abs(chosen.duration - track.duration) <= Self.durationTolerance

        let verdict: Candidate.Verdict = (exact != nil && sameLength) ? .confident : .uncertain
        return Candidate(track: track, match: chosen, alternatives: alternatives, verdict: verdict)
    }

    /// Three seconds. Wide enough for a fade or a catalogue rounding, narrow
    /// enough that a different arrangement doesn't slip through.
    private static let durationTolerance: TimeInterval = 3

    // MARK: - Committing

    public struct Outcome: Sendable {
        /// Spotify's id for the playlist that was just created — what a sync
        /// link points at afterwards.
        public var playlistID: String
        public var playlistURL: URL?
        public var added: Int
        public var skipped: Int
    }

    /// Creates the playlist on Spotify and fills it with the chosen URIs.
    ///
    /// Order is the plan's order, which is the playlist's order here. Songs the
    /// user left unticked are simply absent — this never substitutes a
    /// runner-up for something they declined.
    public func commit(name: String,
                       description: String?,
                       isPublic: Bool,
                       uris: [String],
                       skipped: Int) async throws -> Outcome {
        let signpost = MixSignpost.exporting.beginInterval("export-spotify",
                                                           id: MixSignpost.exporting.makeSignpostID())
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MixSignpost.exporting.endInterval("export-spotify", signpost)
            MixLog.exporting.notice("export-spotify: \(uris.count, privacy: .public) track(s) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms")
        }
        guard !uris.isEmpty else {
            throw SpotifyExportError.nothingToExport
        }
        let token = try await auth.validAccessToken()
        var account = auth.profile?.id
        if account == nil {
            account = try? await client.fetchProfile(accessToken: token).id
        }
        guard let userID = account else { throw SpotifyExportError.noAccount }

        pushed = (0, uris.count)
        defer { pushed = nil }

        let created: (id: String, url: URL?)
        do {
            created = try await client.createPlaylist(
                name:        name,
                description: description,
                isPublic:    isPublic,
                userID:      userID,
                accessToken: token
            )
        } catch SpotifyPlaylistError.writeNotPermitted {
            throw refusalToReport()
        }

        // Chunked here as well as inside `addTracks` so the bar moves: the
        // client's own chunking is invisible from out here, and a nine-hundred
        // song playlist would otherwise sit at zero for nine requests.
        for chunk in uris.chunked(into: 100) {
            try Task.checkCancellation()
            do {
                try await client.addTracks(uris: chunk,
                                           toPlaylist: created.id,
                                           accessToken: token)
            } catch SpotifyPlaylistError.writeNotPermitted {
                throw refusalToReport()
            }
            pushed = ((pushed?.done ?? 0) + chunk.count, uris.count)
        }

        return Outcome(playlistID: created.id,
                       playlistURL: created.url,
                       added: uris.count,
                       skipped: skipped)
    }

    // MARK: - Likes

    /// What a favourites push would actually do, worked out before it does it.
    ///
    /// The push used to be a confirmation dialog and a leap: it planned, wrote,
    /// and reported afterwards. That reads fine at nine hundred songs and badly
    /// at one — "Likes 1 song on Spotify" for a song already in Liked Songs is a
    /// button offering work that doesn't exist. So the check happens first now,
    /// and what comes back is a list of what's *missing* from Spotify rather
    /// than a list of what's favourited here.
    public struct LikesReview: Sendable {
        /// Matched, and not already in the account's library. The only rows the
        /// user is asked about, because they're the only ones that would change
        /// anything.
        public var pushable: [Candidate]
        /// Favourites already in Liked Songs. Counted, not listed: a hundred
        /// rows of "nothing to do here" is not a review, it's a wall. Counted
        /// as *rows*, not as URIs, so two favourites that turn out to be the
        /// same recording still read as two.
        public var alreadyLiked: Int
        /// Searched for and not found. Listed, because "not on Spotify" is a
        /// fact about someone's library they may want to know.
        public var missing: [Candidate]

        /// Whether Spotify answered when asked what was already saved.
        ///
        /// When it doesn't, every match falls through as pushable and
        /// `alreadyLiked` reads zero, which is precisely the behaviour this
        /// page was built to replace. The push is still safe — saving is
        /// idempotent — but the review is guesswork, and it says so rather
        /// than quietly presenting a stale list as a checked one.
        public var checkSucceeded: Bool = true
        /// Songs whose lookup never got an answer — a rate limit, usually.
        /// Not counted as missing, because nobody established that they are.
        public var unchecked: Int = 0
        /// Why, when there were any. Drives the wording, so a rate limit reads
        /// as something to wait out rather than as a mystery.
        public var uncheckedReason: Candidate.Reason?

        /// Nothing to do: everything favourited is either already saved or
        /// isn't on Spotify to save.
        public var hasNothingToPush: Bool { pushable.isEmpty }
    }

    /// Matches every favourite against Spotify and drops the ones already saved.
    ///
    /// Songs matched on an earlier run are taken from the cache and never
    /// searched again; only the ones nothing is known about cost a request.
    public func reviewLikes(_ tracks: [Track]) async throws -> LikesReview {
        guard auth.canWrite else { throw SpotifyExportError.writeNotAllowed }

        var known: [UUID: Candidate] = [:]
        var unknown: [Track] = []
        for track in tracks {
            if let cached = matchCache[track.id.uuidString] {
                known[track.id] = Candidate(track: track,
                                            match: cached.match,
                                            alternatives: [],
                                            verdict: cached.confident ? .confident : .uncertain)
            } else if recentlyMissed(track) {
                known[track.id] = Candidate(track: track, match: nil,
                                            alternatives: [], verdict: .missing)
            } else {
                unknown.append(track)
            }
        }

        if !unknown.isEmpty {
            let plan = try await plan(name: "Liked Songs", tracks: unknown)
            remember(plan.candidates)
            for candidate in plan.candidates { known[candidate.track.id] = candidate }
        }

        // Back into the caller's order: the cached half and the searched half
        // arrive separately, and a favourites list that reshuffles itself
        // depending on what was cached would be its own small bug.
        let candidates = tracks.compactMap { known[$0.id] }
        let matched = candidates.filter { $0.match != nil }
        let uris = Set(matched.compactMap { $0.match?.uri })

        let token = try await auth.validAccessToken()
        var checked = true
        var already: Set<String> = []
        if !uris.isEmpty {
            do {
                already = try await client.likedStatus(uris: Array(uris), accessToken: token)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not fatal — saving is idempotent, so the worst case is being
                // offered songs already saved. But it is not silent either: the
                // review carries the failure so the page can admit to it.
                checked = false
            }
        }

        let pushable = matched.filter { candidate in
            guard let uri = candidate.match?.uri else { return false }
            return !already.contains(uri)
        }

        return LikesReview(pushable: pushable,
                           alreadyLiked: matched.count - pushable.count,
                           missing: candidates.filter { $0.verdict == .missing },
                           checkSucceeded: checked,
                           // A song whose lookup failed is neither pushable nor
                           // missing; it is unknown, and the page says so rather
                           // than presenting a partial answer as a whole one.
                           unchecked: candidates.filter(\.isUnchecked).count,
                           uncheckedReason: candidates.compactMap(\.uncheckedReason).first)
    }

    /// Saves exactly these Spotify URIs to the account's library.
    ///
    /// Takes URIs rather than tracks because by this point the matching has been
    /// done and, more to the point, *reviewed* — re-deriving it here would throw
    /// away the user's corrections and their unticked rows.
    ///
    /// Additive, always. A song unhearted in Mixtape is not a song anyone asked
    /// to unlike on Spotify: the two lists have separate histories and no shared
    /// record of who removed what. That is also what makes it safe to re-run —
    /// saving something already saved is a no-op at Spotify's end.
    @discardableResult
    public func pushLikes(uris: [String]) async throws -> Int {
        guard !uris.isEmpty else { return 0 }
        guard auth.canWrite else { throw SpotifyExportError.writeNotAllowed }

        var token = try await auth.validAccessToken()
        pushed = (0, uris.count)
        defer { pushed = nil }

        for chunk in uris.chunked(into: 40) {
            try Task.checkCancellation()
            do {
                try await client.saveToLikedSongs(uris: chunk, accessToken: token)
            } catch SpotifyPlaylistError.writeNotPermitted {
                throw refusalToReport()
            } catch SpotifyPlaylistError.tokenExpired {
                // One retry on a fresh token, and only for the token itself
                // expiring. A refusal about permissions is not retryable and
                // must reach the user unchanged.
                token = try await auth.refreshedAccessToken()
                try await client.saveToLikedSongs(uris: chunk, accessToken: token)
            }
            pushed = ((pushed?.done ?? 0) + chunk.count, uris.count)
        }
        return uris.count
    }
}

extension SpotifyExportService {
    /// Tells apart the two refusals that look identical from the outside.
    ///
    /// A grant missing `user-library-modify` and an app Spotify won't let write
    /// at all both come back as 403. Only the first is fixed by consenting
    /// again, and sending someone back through a permission screen they have
    /// already agreed to — twice — is worse than saying plainly that the
    /// problem isn't theirs to solve from in here.
    func refusalToReport() -> SpotifyExportError {
        auth.canWrite ? .refusedBySpotify : .writeNotAllowed
    }
}

public enum SpotifyExportError: LocalizedError {
    case nothingToExport
    case noAccount
    /// The connection reads this account but was never allowed to change it.
    case writeNotAllowed
    /// Every permission was granted and Spotify refused the write regardless —
    /// an app-level restriction, which nothing the user does in Mixtape fixes.
    case refusedBySpotify

    public var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "Nothing is ticked, so there's nothing to send to Spotify."
        case .noAccount:
            return "Couldn't tell which Spotify account to write to. Try reconnecting."
        case .refusedBySpotify:
            return "Spotify refused the change even though it granted every permission. This is a restriction on the Mixtape app itself, not on your account \u{2014} reconnecting won't help."
        case .writeNotAllowed:
            return "Mixtape can read this Spotify account but not change it. Disconnect and connect again, allowing it to add things."
        }
    }
}
