// MixEditionStore.swift
// Mixtape - Core/Services/Online
//
// Discover's generated shelves, shared through the account.

import Foundation
import Supabase
import os

/// Each week's shelves are built once per account, by whichever device gets
/// there first, and kept in `generated_shelves`. Every other device reads that
/// copy, so mixes match on macOS, iOS and web. A disk mirror covers the first
/// frame, being offline and being signed out.
enum MixEditionStore {

    /// The row's kind. The suffix is a schema version: bump it to replace every stored copy.
    enum Kind: String {
        case mixes = "mixes.1", radar = "radar.1", stations = "stations.1", genres = "genres.3"
        /// Artist -> genre tags. Not weekly: merged into, never replaced.
        /// .2 matched artists by one of their songs and added German Rap, .3 Apple's genre and language scenes from lyrics.
        case placements = "placements.3"
    }

    private struct Stored<Value: Codable>: Codable {
        let edition: Int64
        let value: Value
        /// False for a build too thin to share (a throttled one), so the next load tries again.
        let complete: Bool
    }

    private struct Row<Value: Codable>: Codable {
        let edition: Int64
        let payload: Value
    }

    /// The payload goes as JSON: the shelf types' Codable is main-actor bound, and the client wants Sendable.
    private struct ClaimParams: Encodable, Sendable {
        let p_kind: String
        let p_edition: Int64
        let p_payload: AnyJSON
    }

    private struct MergeParams: Encodable, Sendable {
        let p_kind: String
        let p_payload: [String: [String]]
    }

    /// Whatever the mirror holds, any week, so the first frame isn't blank.
    static func cached<T: Codable>(_ kind: Kind, as type: T.Type = T.self) -> T? {
        read(kind, as: T.self)?.value
    }

    /// This edition's shelf. The account's copy wins; `build` runs only when there's
    /// none yet, and its result is claimed unless it came back incomplete. A race
    /// between two devices returns the first one's copy to both.
    static func shelf<T: Codable>(_ kind: Kind,
                                  edition: UInt64,
                                  build: () async -> (value: T, complete: Bool)?) async -> T? {
        let edition = Int64(edition)
        let local = read(kind, as: T.self)
        let current = local.map { $0.edition >= edition } ?? false
        let signedIn = SupabaseConfig.client.auth.currentUser != nil

        if signedIn {
            switch await fetch(kind, as: T.self) {
            case .success(let row?) where row.edition >= edition:
                write(Stored(edition: row.edition, value: row.payload, complete: true), kind)
                return row.payload
            case .failure:
                // Offline: this week's copy beats a build that would fail anyway.
                if let local, current { return local.value }
            default:
                break
            }
        } else if let local, current, local.complete {
            return local.value
        }

        // A complete build that never reached the server (offline at the time) goes up as it is.
        let fresh: (value: T, complete: Bool)
        if signedIn, let local, current, local.complete {
            fresh = (local.value, true)
        } else if let built = await build() {
            fresh = built
        } else {
            return local?.value
        }

        if signedIn, fresh.complete, let winner = await claim(fresh.value, kind: kind, edition: edition) {
            write(Stored(edition: winner.edition, value: winner.payload, complete: true), kind)
            return winner.payload
        }
        write(Stored(edition: edition, value: fresh.value, complete: fresh.complete), kind)
        return fresh.value
    }

    /// Forgets every shelf. A wipe clears the account's copies too; an account
    /// switch only this device's, since the rows belong to the old account.
    static func clear(remote: Bool) {
        try? FileManager.default.removeItem(at: directory)
        ArtistGenreStore.clear()
        guard remote, let userID = SupabaseConfig.client.auth.currentUser?.id else { return }
        Task {
            do {
                try await SupabaseConfig.client.from("generated_shelves")
                    .delete(returning: .minimal)
                    .eq("user_id", value: userID)
                    .execute()
            } catch {
                MixLog.sync.error("[Shelves] clear: \(error.localizedDescription)")
            }
        }
    }

    /// The account's artist tags, nil when signed out or unreachable.
    static func placements() async -> [String: [String]]? {
        guard case .success(let row?) = await fetch(.placements, as: [String: [String]].self) else { return nil }
        return row.payload
    }

    static func addPlacements(_ learned: [String: [String]]) async {
        guard SupabaseConfig.client.auth.currentUser != nil else { return }
        do {
            try await SupabaseConfig.client
                .rpc("merge_generated_shelf", params: MergeParams(p_kind: Kind.placements.rawValue, p_payload: learned))
                .execute()
        } catch {
            MixLog.sync.error("[Shelves] placements: \(error.localizedDescription)")
        }
    }

    // MARK: Server

    private static func fetch<T: Codable>(_ kind: Kind, as type: T.Type) async -> Result<Row<T>?, Error> {
        guard let userID = SupabaseConfig.client.auth.currentUser?.id else { return .success(nil) }
        do {
            let data = try await SupabaseConfig.client.from("generated_shelves")
                .select("edition,payload")
                .eq("user_id", value: userID)
                .eq("kind", value: kind.rawValue)
                .limit(1)
                .execute().data
            return .success(try JSONDecoder().decode([Row<T>].self, from: data).first)
        } catch {
            MixLog.sync.error("[Shelves] fetch \(kind.rawValue): \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func claim<T: Codable>(_ value: T, kind: Kind, edition: Int64) async -> Row<T>? {
        do {
            let payload = try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value))
            let data = try await SupabaseConfig.client
                .rpc("claim_generated_shelf", params: ClaimParams(p_kind: kind.rawValue, p_edition: edition, p_payload: payload))
                .execute().data
            return try JSONDecoder().decode([Row<T>].self, from: data).first
        } catch {
            MixLog.sync.error("[Shelves] claim \(kind.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Mirror

    private static func read<T: Codable>(_ kind: Kind, as type: T.Type) -> Stored<T>? {
        guard let data = try? Data(contentsOf: url(kind)) else { return nil }
        return try? JSONDecoder().decode(Stored<T>.self, from: data)
    }

    private static func write<T: Codable>(_ stored: Stored<T>, _ kind: Kind) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url(kind), options: .atomic)
    }

    private static func url(_ kind: Kind) -> URL {
        directory.appendingPathComponent("\(kind.rawValue).json")
    }

    /// Application Support, not Caches, so a purge doesn't redraw the week.
    static let directory: URL = (FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL.documentsDirectory)
        .appendingPathComponent("Mixtape", isDirectory: true)
        .appendingPathComponent("Discover", isDirectory: true)
}

// MARK: - Wire format
// The rows are read by the web too, so these encode the web's JSON shapes
// (src/lib/catalogTypes.ts). Decoding is lenient about what either side leaves out.

/// The personal landing minus the slow shelves, which are rows of their own.
struct LandingWire: Codable, Sendable {
    struct Related: Codable, Sendable {
        let seedName: String
        let artists: [OnlineArtist]
    }

    var seeds: [String]
    var mixes: [PersonalMix]
    var recommended: [OnlineTrack]
    var related: [Related]
    var newRelease: OnlineAlbum?
    var newReleaseArtist: OnlineArtist?
    var freshReleases: [OnlineAlbum]
    var edition: UInt64
    var fingerprint: String

    init(_ landing: PersonalLanding) {
        seeds = landing.seeds
        mixes = landing.mixes
        recommended = landing.recommendedPool
        related = landing.related.map { Related(seedName: $0.seedArtist, artists: $0.artists) }
        newRelease = landing.newRelease?.album
        newReleaseArtist = landing.newRelease?.artist
        freshReleases = landing.freshReleases
        edition = RecommendationEngine.edition()
        fingerprint = landing.fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case seeds, mixes, recommended, related, newRelease, newReleaseArtist, freshReleases, edition, fingerprint
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seeds            = try box.decodeIfPresent([String].self, forKey: .seeds) ?? []
        mixes            = try box.decodeIfPresent([PersonalMix].self, forKey: .mixes) ?? []
        recommended      = try box.decodeIfPresent([OnlineTrack].self, forKey: .recommended) ?? []
        related          = try box.decodeIfPresent([Related].self, forKey: .related) ?? []
        newRelease       = try box.decodeIfPresent(OnlineAlbum.self, forKey: .newRelease)
        newReleaseArtist = try box.decodeIfPresent(OnlineArtist.self, forKey: .newReleaseArtist)
        freshReleases    = try box.decodeIfPresent([OnlineAlbum].self, forKey: .freshReleases) ?? []
        edition          = try box.decodeIfPresent(UInt64.self, forKey: .edition) ?? 0
        fingerprint      = try box.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
    }

    /// Back to a landing, carrying over the shelves that load separately.
    func landing(keeping shelves: PersonalLanding) -> PersonalLanding {
        var hero: FreshRelease?
        if let newRelease, let newReleaseArtist { hero = FreshRelease(album: newRelease, artist: newReleaseArtist) }
        return PersonalLanding(
            seeds: seeds,
            mixes: mixes,
            newRelease: hero,
            recommendedPool: recommended,
            related: related.map {
                RelatedArtistRow(id: RecommendationEngine.normalize($0.seedName), seedArtist: $0.seedName, artists: $0.artists)
            },
            freshReleases: freshReleases,
            releaseRadar: shelves.releaseRadar,
            genreMixes: shelves.genreMixes,
            stations: shelves.stations,
            fingerprint: fingerprint
        )
    }
}

extension PersonalMix {
    private enum WireKeys: String, CodingKey {
        case id, seedName, seedArtist, title, subtitle, tracks, covers
    }

    /// Reads `seedName` (web) or `seedArtist` (mirrors written before the rows existed).
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: WireKeys.self)
        self.init(
            id: try box.decode(String.self, forKey: .id),
            seedArtist: try box.decodeIfPresent(String.self, forKey: .seedName)
                ?? box.decodeIfPresent(String.self, forKey: .seedArtist) ?? "",
            title: try box.decode(String.self, forKey: .title),
            subtitle: try box.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            tracks: try box.decodeIfPresent([OnlineTrack].self, forKey: .tracks) ?? [],
            covers: (try box.decodeIfPresent([String].self, forKey: .covers) ?? []).compactMap(URL.init(string:))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: WireKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(seedArtist, forKey: .seedName)
        try box.encode(title, forKey: .title)
        try box.encode(subtitle, forKey: .subtitle)
        try box.encode(tracks, forKey: .tracks)
        try box.encode(covers.map(\.absoluteString), forKey: .covers)
    }
}

extension OnlineArtist: Codable {
    private enum WireKeys: String, CodingKey { case id, name, pictureURL, fans }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: WireKeys.self)
        self.init(id: try box.decode(Int.self, forKey: .id),
                  name: try box.decode(String.self, forKey: .name),
                  imageURL: (try? box.decodeIfPresent(String.self, forKey: .pictureURL)).flatMap(URL.init(string:)))
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: WireKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(name, forKey: .name)
        try box.encode(imageURL?.absoluteString, forKey: .pictureURL)
        try box.encode(0, forKey: .fans)
    }
}

extension OnlineAlbum: Codable {
    private enum WireKeys: String, CodingKey {
        case id, title, artistName, artistID, coverURL, releaseDate, recordType, trackCount
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: WireKeys.self)
        self.init(id: try box.decode(Int.self, forKey: .id),
                  title: try box.decode(String.self, forKey: .title),
                  artistName: try box.decodeIfPresent(String.self, forKey: .artistName) ?? "",
                  coverURL: (try? box.decodeIfPresent(String.self, forKey: .coverURL)).flatMap(URL.init(string:)),
                  releaseDate: ITunesSearchClient.deezerDate(try? box.decodeIfPresent(String.self, forKey: .releaseDate)),
                  recordType: try? box.decodeIfPresent(String.self, forKey: .recordType),
                  trackCount: try? box.decodeIfPresent(Int.self, forKey: .trackCount))
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: WireKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(title, forKey: .title)
        try box.encode(artistName, forKey: .artistName)
        try box.encodeNil(forKey: .artistID)
        try box.encode(coverURL?.absoluteString, forKey: .coverURL)
        try box.encode(releaseDate.map(Self.dayString), forKey: .releaseDate)
        try box.encode(recordType, forKey: .recordType)
        try box.encode(trackCount, forKey: .trackCount)
    }

    /// "yyyy-MM-dd" in UTC, the form Deezer sends and `deezerDate` parses.
    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
