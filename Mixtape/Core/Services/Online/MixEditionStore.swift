// MixEditionStore.swift
// Mixtape — Core/Services/Online
//
// This week's mixes, on disk.

import Foundation

/// Where a week's mixes live between builds.
///
/// `RecommendationEngine` draws a mix deterministically from the artist and the
/// week, so the same radio always yields the same twenty-four songs in the same
/// order. The radio is what isn't stable: Deezer answers `/artist/{id}/radio`
/// with a different fifty tracks every time it's asked, so redrawing inside one
/// week still produced a visibly different "Travis Scott Mix".
///
/// And redraws are frequent. The landing page is invalidated by the seeds as
/// well as by the clock, and the seeds move whenever the user plays something or
/// saves a mix — so saving a mix and walking back to Home was enough to rebuild
/// every card on the page. Which is exactly what it looked like.
///
/// Pinning the *drawn result*, keyed by edition, is the only thing that makes a
/// mix hold still. When the week turns over the stored edition no longer
/// matches, and the next build draws — and stores — a new set.
enum MixEditionStore {

    private struct Snapshot: Codable {
        let edition: UInt64
        let mixes: [PersonalMix]
    }

    /// The mixes stored for `edition`, or nil when there are none — including
    /// when the stored ones belong to a week that has since ended.
    static func load(edition: UInt64) -> [PersonalMix]? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.edition == edition,
              !snapshot.mixes.isEmpty
        else { return nil }
        return snapshot.mixes
    }

    /// What to show for `edition`, given the set a build just produced — and the
    /// set that's now stored for it.
    ///
    /// A mix already drawn this edition always beats the same mix redrawn; that's
    /// the pinning above. This is the other half of it. Deezer throttles, and a
    /// throttled radio leg yields no mix at all rather than a thin one, so a build
    /// that ran into the quota comes back with four cards instead of six — and
    /// pinning wholesale would have hung that shortfall on the whole week. Merging
    /// by id instead means a later build can fill the gaps while everything
    /// already pinned stays exactly where it is, in the order it was drawn.
    ///
    /// New mixes go on the end and stop at `limit`, so the row can't grow past
    /// what a single build would have produced.
    static func reconcile(_ fresh: [PersonalMix], edition: UInt64, limit: Int) -> [PersonalMix] {
        let pinned = load(edition: edition) ?? []
        guard !pinned.isEmpty else {
            save(fresh, edition: edition)
            return fresh
        }

        var merged = pinned
        var seen = Set(pinned.map(\.id))
        for mix in fresh where seen.insert(mix.id).inserted {
            guard merged.count < limit else { break }
            merged.append(mix)
        }

        if merged.count != pinned.count { save(merged, edition: edition) }
        return merged
    }

    static func save(_ mixes: [PersonalMix], edition: UInt64) {
        guard !mixes.isEmpty,
              let data = try? JSONEncoder().encode(Snapshot(edition: edition, mixes: mixes))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Forget the stored week entirely — the taste they were drawn from is gone.
    ///
    /// The pinning above is deliberate and strong: a mix drawn for this edition
    /// beats any redraw, and the file lives in Application Support so that even
    /// a purged cache can't undo it. That is exactly right for the case it was
    /// built for and exactly wrong for a wipe, where it made the old mixes the
    /// one piece of the user's taste that a "delete everything" couldn't reach.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: radarURL)
        for name in ["genres", "stations"] { try? FileManager.default.removeItem(at: listURL(name)) }
        ArtistGenreStore.clear()
    }

    // MARK: Other pinned lists

    /// Genre mixes and stations pin the same way, under their own names. `key`
    /// is whatever the list is supposed to hold still for — the week for
    /// stations, the taste it was clustered from for genre mixes.
    static func loadList(_ name: String, key: UInt64) -> [PersonalMix]? {
        guard let data = try? Data(contentsOf: listURL(name)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.edition == key,
              !snapshot.mixes.isEmpty
        else { return nil }
        return snapshot.mixes
    }

    /// Whatever is stored under `name`, whatever it was pinned for.
    ///
    /// The landing draws these on the first frame and only *then* checks
    /// whether they're still right — a genre shelf takes seconds to cluster and
    /// a page that waits for it is a page that waits. A stale shelf for one
    /// paint beats a blank one.
    static func loadList(_ name: String) -> [PersonalMix]? {
        guard let data = try? Data(contentsOf: listURL(name)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.mixes.isEmpty
        else { return nil }
        return snapshot.mixes
    }

    static func saveList(_ mixes: [PersonalMix], name: String, key: UInt64) {
        guard !mixes.isEmpty,
              let data = try? JSONEncoder().encode(Snapshot(edition: key, mixes: mixes))
        else { return }
        try? data.write(to: listURL(name), options: .atomic)
    }

    private static func listURL(_ name: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(name).json")
    }

    // MARK: Release Radar

    /// The radar is pinned for the same reason and in the same way, in its own
    /// file: building it reads the whole library, so it costs a request per
    /// artist and must run once a week rather than once a page.
    static func loadRadar(edition: UInt64) -> PersonalMix? {
        guard let data = try? Data(contentsOf: radarURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.edition == edition
        else { return nil }
        return snapshot.mixes.first
    }

    static func saveRadar(_ mix: PersonalMix, edition: UInt64) {
        guard let data = try? JSONEncoder().encode(Snapshot(edition: edition, mixes: [mix]))
        else { return }
        try? data.write(to: radarURL, options: .atomic)
    }

    /// `Application Support/Mixtape/Discover/mixes.json`.
    ///
    /// Application Support rather than Caches: a purged cache would silently
    /// regenerate the week's mixes, which is the behaviour this exists to stop.
    private static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory

        let dir = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Discover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent("mixes.json")
    }()

    private static let radarURL: URL = url
        .deletingLastPathComponent()
        .appendingPathComponent("radar.json")
}
