// Maps library spellings of artists to catalogue ones ("Digga" -> "Digga D").
// Linked rather than renamed, since the track id hashes the artist.
// Learned whenever a local name resolves to a catalogue artist. Global, not per account.

import Foundation

enum ArtistAliases {

    private static let key = "mix.artistAliases"

    /// Records `local` as this library's spelling of `canonical`.
    static func record(local: String, canonical: String) {
        let folded = fold(local)
        guard !folded.isEmpty, !fold(canonical).isEmpty, folded != fold(canonical) else { return }
        var map = stored()
        guard map[folded] != canonical else { return }
        map[folded] = canonical
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Every spelling of `canonical`, folded. Read once per pass.
    static func spellings(of canonical: String) -> Set<String> {
        let wanted = fold(canonical)
        guard !wanted.isEmpty else { return [] }
        var out: Set<String> = [wanted]
        for (local, target) in stored() where fold(target) == wanted { out.insert(local) }
        return out
    }

    /// DiscoverNameMatch folding minus a leading "the".
    static func fold(_ name: String) -> String {
        DiscoverNameMatch.withoutLeadingThe(DiscoverNameMatch.normalize(name))
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
