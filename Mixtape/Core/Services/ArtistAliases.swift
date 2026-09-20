// ArtistAliases.swift
// Mixtape — Core/Services
//
// What the catalogue calls an artist this library spells differently.
//
// A Discover artist page carries no local id, so a name is the only bridge to
// the library (see `DiscoverArtistCounts.isCredited`). When the two spellings
// disagree the bridge breaks silently: songs credited "Digga" here, opened
// against a Deezer page titled "Digga D", count as "no liked songs" on a page
// full of songs you own.
//
// Renaming the library rows to match is not an option. `OnlineTrack.id` is
// "title|artist" and `stableTrackID` hashes it, so a credit that changed would
// hash to a *different* track — a duplicate row, split play counts, and a cache
// miss on a file already on disk (the argument is spelled out in full on
// `ImportService.displayArtists`). So the two names are linked, not merged.
//
// Learned rather than configured: every time a local spelling is resolved to a
// catalogue artist — which is every time one is tapped — the answer is written
// down. That is the checking, and it costs no extra request.
//
// Deliberately in `UserDefaults.standard` and not per-account: "Digga means
// Digga D" is a fact about the catalogue, not about a user's library.

import Foundation

enum ArtistAliases {

    private static let key = "mix.artistAliases"

    /// Records that `local` is how this library spells the catalogue's
    /// `canonical`. The same name under a different casing records nothing.
    static func record(local: String, canonical: String) {
        let folded = fold(local)
        guard !folded.isEmpty, !fold(canonical).isEmpty, folded != fold(canonical) else { return }
        var map = stored()
        guard map[folded] != canonical else { return }
        map[folded] = canonical
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Every spelling that means `canonical`, already folded for comparison:
    /// the name itself, plus each local spelling that has resolved to it.
    ///
    /// Read once per pass, not once per track — this is a defaults lookup and
    /// the callers walk whole playlists.
    static func spellings(of canonical: String) -> Set<String> {
        let wanted = fold(canonical)
        guard !wanted.isEmpty else { return [] }
        var out: Set<String> = [wanted]
        for (local, target) in stored() where fold(target) == wanted { out.insert(local) }
        return out
    }

    /// The comparison form: `DiscoverNameMatch`'s folding, minus a leading
    /// "the", so "The Weeknd" and "Weeknd" are one artist here too.
    static func fold(_ name: String) -> String {
        DiscoverNameMatch.withoutLeadingThe(DiscoverNameMatch.normalize(name))
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
