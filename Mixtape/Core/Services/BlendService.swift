// Blend: one playlist two people share, built from both of their listening.
// The owner shares an invite link, the other person joins with it. Once a day the
// first member's device to open it builds the playlist and claims it, and both read
// that copy (supabase/migrations/20261002000000_blends.sql). Same payload as
// mixtape-web src/lib/blend.ts, keep them in sync.

import Foundation
import Combine
import os
import Supabase

@MainActor
public final class BlendService: ObservableObject {

    public struct Blend: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let code: String
        /// Nil until someone joins the invite.
        public let otherName: String?
        public var mix: PersonalMix?
        public var isPending: Bool { otherName == nil }
    }

    @Published public private(set) var blends: [Blend] = []

    private let client: SupabaseClient
    private let catalog: ITunesSearchClient
    private let toast: (Toast) -> Void

    public init(client: SupabaseClient, catalog: ITunesSearchClient, toast: @escaping (Toast) -> Void) {
        self.client = client
        self.catalog = catalog
        self.toast = toast
    }

    public static func link(code: String) -> URL { MixtapeLink.web("blend/\(code)") }

    // MARK: - Calls

    private struct Row: Decodable {
        let id: UUID
        let code: String
        let other_name: String?
        let edition: Int64
        let payload: Payload?
    }

    struct Payload: Codable, Sendable {
        let score: Int
        let tracks: [OnlineTrack]
    }

    /// Loads the caller's Blends and builds today's playlist for any that are stale.
    public func refresh() async {
        guard let rows: [Row] = try? await client.rpc("my_blends").execute().value else { return }
        let today = Self.edition()
        blends = rows.map { row in
            Blend(id: row.id, code: row.code, otherName: row.other_name,
                  mix: row.payload.map { Self.mix(id: row.id, other: row.other_name, payload: $0) })
        }
        for row in rows where row.other_name != nil && row.edition < today {
            guard let payload = await build(row.id), !payload.tracks.isEmpty,
                  let stored = await claim(row.id, edition: today, payload: payload),
                  let i = blends.firstIndex(where: { $0.id == row.id }) else { continue }
            blends[i].mix = Self.mix(id: row.id, other: row.other_name, payload: stored)
        }
    }

    /// The invite link for the caller's open invite, made if there isn't one.
    public func invite() async -> URL? {
        struct Created: Decodable { let id: UUID; let code: String }
        do {
            let c: Created = try await client.rpc("create_blend").execute().value
            await refresh()
            return Self.link(code: c.code)
        } catch {
            MixLog.sync.error("[Blend] create failed: \(error)")
            toast(.failed("Couldn\u{2019}t make a Blend invite", error))
            return nil
        }
    }

    public func join(code raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        struct Joined: Decodable { let id: UUID }
        do {
            let j: Joined = try await client.rpc("join_blend", params: ["p_code": code]).execute().value
            await refresh()
            let name = blends.first { $0.id == j.id }?.otherName ?? "them"
            toast(.done("You\u{2019}re blending with \(name)"))
        } catch {
            switch (error as? PostgrestError)?.code {
            case "P0002": toast(.failed("That Blend invite has expired"))
            case "42501": toast(.failed("You can\u{2019}t join that Blend"))
            default:      toast(.failed("Couldn\u{2019}t join the Blend", error))
            }
        }
    }

    public func leave(_ id: UUID) async {
        do {
            try await client.rpc("leave_blend", params: ["p_blend": id]).execute()
            blends.removeAll { $0.id == id }
        } catch {
            toast(.failed("Couldn\u{2019}t leave the Blend", error))
        }
    }

    // MARK: - Building

    struct Taste: Decodable, Sendable {
        struct Song: Decodable, Sendable { let title: String; let artist: String; let plays: Int }
        struct Artist: Decodable, Sendable { let name: String; let plays: Int }
        let tracks: [Song]
        let artists: [Artist]
    }

    private static let length = 40

    private func build(_ id: UUID) async -> Payload? {
        guard let tastes: [Taste] = try? await client.rpc("blend_tastes", params: ["p_blend": id]).execute().value,
              tastes.count == 2 else { return nil }
        let (picks, shared) = Self.merge(tastes[0], tastes[1])

        var tracks = await resolve(picks)
        if tracks.count < Self.length {
            // ponytail: radio from the artists you share, or each person's top artist.
            let seeds = shared.isEmpty ? tastes.compactMap { $0.artists.first?.name } : Array(shared.prefix(3))
            for seed in seeds where tracks.count < Self.length {
                tracks += await catalog.radioTracks(forArtist: seed, limit: 10)
            }
        }
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.id).inserted }
        return Payload(score: Self.score(tastes[0], tastes[1]), tracks: Array(tracks.prefix(Self.length)))
    }

    private func resolve(_ picks: [(title: String, artist: String)]) async -> [OnlineTrack] {
        let catalog = catalog
        return await withTaskGroup(of: (Int, OnlineTrack?).self) { group in
            for (i, pick) in picks.enumerated() {
                group.addTask { (i, await catalog.resolveOnlineTrack(title: pick.title, artist: pick.artist)) }
            }
            var out: [(Int, OnlineTrack)] = []
            for await (i, track) in group { if let track { out.append((i, track)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func claim(_ id: UUID, edition: Int64, payload: Payload) async -> Payload? {
        struct Params: Encodable, Sendable { let p_blend: UUID; let p_edition: Int64; let p_payload: AnyJSON }
        struct Stored: Decodable { let payload: Payload? }
        do {
            let json = try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(payload))
            let rows: [Stored] = try await client
                .rpc("claim_blend", params: Params(p_blend: id, p_edition: edition, p_payload: json))
                .execute().value
            return rows.first?.payload
        } catch {
            MixLog.sync.error("[Blend] claim failed: \(error)")
            return nil
        }
    }

    /// Songs you both play first, then the two lists taking turns.
    static func merge(_ a: Taste, _ b: Taste) -> (picks: [(title: String, artist: String)], sharedArtists: [String]) {
        func key(_ s: Taste.Song) -> String {
            "\(RecommendationEngine.normalize(s.title))|\(RecommendationEngine.normalize(s.artist))"
        }
        let bPlays = Dictionary(b.tracks.map { (key($0), $0.plays) }, uniquingKeysWith: +)
        let both = a.tracks.filter { bPlays[key($0)] != nil }
            .sorted { $0.plays + bPlays[key($0)]! > $1.plays + bPlays[key($1)]! }
        let bothKeys = Set(both.map(key))
        let aOnly = a.tracks.filter { !bothKeys.contains(key($0)) }
        let bOnly = b.tracks.filter { !bothKeys.contains(key($0)) }

        var picks = both.map { (title: $0.title, artist: $0.artist) }
        for i in 0..<max(aOnly.count, bOnly.count) where picks.count < length {
            if i < aOnly.count { picks.append((aOnly[i].title, aOnly[i].artist)) }
            if i < bOnly.count { picks.append((bOnly[i].title, bOnly[i].artist)) }
        }

        let bArtists = Set(b.artists.map { RecommendationEngine.normalize($0.name) })
        let shared = a.artists.filter { bArtists.contains(RecommendationEngine.normalize($0.name)) }.map(\.name)
        return (Array(picks.prefix(length)), shared)
    }

    /// How much of each person's listening goes to the same artists, 0-100.
    /// ponytail: overlap of artist shares, square-rooted so a few shared favourites read as a real match.
    static func score(_ a: Taste, _ b: Taste) -> Int {
        func shares(_ t: Taste) -> [String: Double] {
            let total = Double(max(t.artists.reduce(0) { $0 + $1.plays }, 1))
            return Dictionary(t.artists.map { (RecommendationEngine.normalize($0.name), Double($0.plays) / total) },
                              uniquingKeysWith: +)
        }
        let sa = shares(a), sb = shares(b)
        let overlap = sa.reduce(0.0) { $0 + min($1.value, sb[$1.key] ?? 0) }
        return Int((overlap.squareRoot() * 100).rounded())
    }

    static func edition(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 / 86_400) }

    private static func mix(id: UUID, other: String?, payload: Payload) -> PersonalMix {
        var seen = Set<URL>()
        let covers = payload.tracks.compactMap(\.artworkURL).filter { seen.insert($0).inserted }
        return PersonalMix(id: "blend-\(id.uuidString.lowercased())",
                           seedArtist: "",
                           title: "You + \(other ?? "Blend")",
                           subtitle: "\(payload.score)% taste match",
                           tracks: payload.tracks,
                           covers: Array(covers.prefix(4)))
    }
}
