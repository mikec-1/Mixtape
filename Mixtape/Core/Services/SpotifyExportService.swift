// Mixtape -> Spotify: playlists recreated on Spotify and Favourites pushed
// to Liked Songs. One-shot, not a mirror: without Spotify ids every match is a
// search, so it plans first and only writes what the user has reviewed.
// Verdicts: `confident` (name matches, runtime within tolerance, ticked),
// `uncertain` (shown, unticked), `missing` (nothing found).
// Likes push only ever adds.

import Foundation
import OSLog
import Combine
import Observation

@Observable
@MainActor
public final class SpotifyExportService {

    // MARK: - Plan

    public struct Candidate: Identifiable, Sendable {

        public enum Verdict: Sendable, Equatable {
            case confident
            case uncertain
            case missing
            /// The lookup failed, which is not the same as "not on Spotify". Carries the reason.
            case unchecked(Reason)
        }

        /// Why a lookup produced no answer.
        public enum Reason: Sendable, Equatable {
            /// Throttled, with Spotify's advised wait if given.
            case rateLimited(retryAfter: TimeInterval)
            /// Offline, dropped connection or a bad reply.
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

        /// Why lookups went unchecked. A run stops at the first rate limit, so there's one cause.
        public var uncheckedReason: Candidate.Reason? {
            candidates.compactMap(\.uncheckedReason).first
        }
    }

    // MARK: - Published

    /// Songs looked up so far, out of how many, while a plan is being built.
    public private(set) var planned: (done: Int, total: Int)?
    /// Songs written so far, out of how many, while a plan is being committed.
    public private(set) var pushed: (done: Int, total: Int)?

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

    /// A found match, cached since title, artist and length don't change.
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

    /// A cached miss. Expires after `missTTL` so new catalogue additions surface,
    /// without re-searching the whole library on every visit.
    private struct CachedMiss: Codable {
        var checkedAt: Date
    }

    /// How long a "Spotify doesn't have this" answer is trusted before it is
    /// asked again. Long enough that repeated visits are free, short enough
    /// that a newly added record surfaces without anyone thinking about it.
    private static let missTTL: TimeInterval = 30 * 24 * 60 * 60

    @ObservationIgnored private var matchCache: [String: CachedMatch] = [:]
    @ObservationIgnored private var missCache:  [String: CachedMiss]  = [:]
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
        // Drop expired misses on load.
        let cutoff = Date().addingTimeInterval(-Self.missTTL)
        missCache = decoded.filter { $0.value.checkedAt > cutoff }
    }

    private func saveMissCache() {
        guard let data = try? JSONEncoder().encode(missCache) else { return }
        defaults.set(data, forKey: Self.missCacheKey)
    }

    /// Recently searched and not found. Failed lookups never count.
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

    /// Clears cached matches; they're keyed by local track id, so per account.
    public func forgetMatches() {
        matchCache.removeAll()
        missCache.removeAll()
        defaults.removeObject(forKey: Self.matchCacheKey)
        defaults.removeObject(forKey: Self.missCacheKey)
    }

    public var canExport: Bool { auth.isAuthorized && auth.canWrite }

    // MARK: - Planning

    /// Looks up and judges every song. Sequential, since parallel searches just hit 429s.
    public func plan(name: String, tracks: [Track]) async throws -> Plan {
        var token = try await auth.validAccessToken()
        let total = tracks.count
        planned = (0, total)
        defer { planned = nil }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(total)

        // After a 429, mark the rest unchecked without requesting.
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

            // Cache hit.
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

            // Refresh the token as we go; long runs outlive it and failed searches are swallowed below.
            if index > 0, index % 50 == 0 {
                token = (try? await auth.validAccessToken()) ?? token
            }

            // Not `try?`: a swallowed error looks like "not on Spotify".
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

            // Yield so judging doesn't hold the main actor between requests.
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

        // Prefer an exact identity match over Spotify's top result. Features can be
        // in the title or the artist field on either side, and both count as exact.
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

        // Also check length, to catch live takes and edits. Skipped when our duration is unknown.
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
        /// The new Spotify playlist's id, for sync links.
        public var playlistID: String
        public var playlistURL: URL?
        public var added: Int
        public var skipped: Int
    }

    /// Creates the playlist and adds the chosen URIs in plan order. Unticked songs
    /// are left out, never substituted.
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

        // Chunked here too so progress moves per request.
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

    /// What a likes push would do, computed first: only matched songs not already
    /// in Liked Songs are offered.
    public struct LikesReview: Sendable {
        /// Matched and not yet liked. The only rows the user reviews.
        public var pushable: [Candidate]
        /// Already liked, counted by row not URI.
        public var alreadyLiked: Int
        /// Searched and not found.
        public var missing: [Candidate]

        /// Whether the already-saved check succeeded. If not, every match shows as
        /// pushable (still safe, saving is idempotent) and the page says so.
        public var checkSucceeded: Bool = true
        /// Lookups that got no answer. Not counted as missing.
        public var unchecked: Int = 0
        /// Drives the wording for unchecked songs.
        public var uncheckedReason: Candidate.Reason?

        /// Nothing to do: everything favourited is either already saved or
        /// isn't on Spotify to save.
        public var hasNothingToPush: Bool { pushable.isEmpty }
    }

    /// Matches favourites against Spotify (cached where possible) and drops ones already saved.
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

        // Restore the caller's order after merging cached and searched results.
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
                // Not fatal; the review flags it.
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
                           // Failed lookups are unknown, not pushable or missing.
                           unchecked: candidates.filter(\.isUnchecked).count,
                           uncheckedReason: candidates.compactMap(\.uncheckedReason).first)
    }

    /// Saves these URIs to Liked Songs. Takes the reviewed URIs, not tracks, to
    /// keep the user's choices. Additive only, and safe to re-run.
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
                // One retry on a fresh token for expiry only; permission refusals pass through.
                token = try await auth.refreshedAccessToken()
                try await client.saveToLikedSongs(uris: chunk, accessToken: token)
            }
            pushed = ((pushed?.done ?? 0) + chunk.count, uris.count)
        }
        return uris.count
    }
}

extension SpotifyExportService {
    /// Both a missing `user-library-modify` scope and an app-level block are 403s.
    /// Only the first is fixed by re-consenting.
    func refusalToReport() -> SpotifyExportError {
        auth.canWrite ? .refusedBySpotify : .writeNotAllowed
    }
}

public enum SpotifyExportError: LocalizedError {
    case nothingToExport
    case noAccount
    /// The connection reads this account but was never allowed to change it.
    case writeNotAllowed
    /// Spotify refused despite full permissions; nothing the user can fix.
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
