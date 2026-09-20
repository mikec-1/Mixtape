// LyricVersion.swift
// Mixtape — Core/Services
//
// Does a lyrics record name the same *recording* as the song we're playing?
// Split out of `LyricsService` so it has no dependencies and can be exercised
// on its own with a standalone `swiftc` check.

import Foundation

enum LyricVersion {

    /// The bracketed groups of a title plus its `- suffix` tail, lowercased and
    /// trimmed: the places a version qualifier is ever written.
    static func qualifierSegments(_ title: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        var tailStart: String.Index? = nil
        var index = title.startIndex
        while index < title.endIndex {
            let c = title[index]
            if c == "(" || c == "[" {
                depth += 1
                if depth == 1 { current = ""; tailStart = nil }
            } else if c == ")" || c == "]" {
                if depth == 1 { segments.append(current.trimmingCharacters(in: .whitespaces)) }
                depth = max(0, depth - 1)
            } else if depth > 0 {
                current.append(c)
            } else if c == "-" || c == "\u{2013}" || c == "\u{2014}" {
                tailStart = title.index(after: index)
            }
            index = title.index(after: index)
        }
        if let tailStart, tailStart <= title.endIndex {
            segments.append(String(title[tailStart...]).trimmingCharacters(in: .whitespaces))
        }
        return segments.filter { !$0.isEmpty }
    }

    /// Version qualifiers for comparison: every bracketed or dash-suffixed
    /// segment that names a *different recording* — "(W&W Remix)", "- Live",
    /// "(Acoustic)" — flattened to bare letters and digits.
    ///
    /// `bareTitle` deliberately throws these away, which is right for matching
    /// a song across uploaders who each punctuate "(feat. …)" differently, and
    /// wrong for a remix: "Don't Let Me Down (W&W Remix)" bares down to the
    /// original, so the original's lyrics — correct words, useless timing —
    /// win the match. Spaces and punctuation are dropped rather than tokenised
    /// so "W&W", "W & W" and "WW" are one key.
    ///
    /// Credits (`feat.`, `with`) and remasters are not version qualifiers: a
    /// remaster is the same performance, and gating on it would lose lyrics
    /// that are perfectly correct.
    static func versionKey(_ title: String) -> String {
        let keywords = ["remix", "mix", "version", "edit", "live", "acoustic",
                        "instrumental", "demo", "reprise", "cover", "bootleg",
                        "dub", "radio", "extended", "sped", "slowed", "vip",
                        "flip", "rework", "unplugged", "session", "karaoke"]
        var segments: [String] = []
        for segment in qualifierSegments(title.lowercased()) {
            guard !segment.hasPrefix("feat"), !segment.hasPrefix("ft"),
                  !segment.hasPrefix("with"), !segment.contains("remaster") else { continue }
            guard keywords.contains(where: { segment.contains($0) }) else { continue }
            segments.append(segment.filter { $0.isLetter || $0.isNumber })
        }
        return segments.sorted().joined()
    }

    /// True when two titles name the same *recording*. Either both are plain or
    /// both carry the same qualifier; a key that merely extends the other
    /// ("(W&W Remix) [Extended]") still matches, so a slightly differently
    /// labelled upload of the right remix isn't thrown away.
    static func sameVersion(_ a: String, _ b: String) -> Bool {
        let (x, y) = (versionKey(a), versionKey(b))
        if x.isEmpty != y.isEmpty { return false }
        return x.isEmpty || x.contains(y) || y.contains(x)
    }
}
