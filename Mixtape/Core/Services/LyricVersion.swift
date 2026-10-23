// Whether a lyrics record matches the same recording. No dependencies,
// so it can be tested alone.

import Foundation

nonisolated enum LyricVersion {

    /// Bracketed groups and the "- suffix", lowercased.
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

    /// Version qualifiers ("(W&W Remix)", "- Live") reduced to letters and digits.
    /// bareTitle drops these, which would match a remix to the original's lyrics.
    /// Credits and remasters aren't versions.
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

    /// Same recording: both plain, or the same qualifier (one may extend the other).
    static func sameVersion(_ a: String, _ b: String) -> Bool {
        let (x, y) = (versionKey(a), versionKey(b))
        if x.isEmpty != y.isEmpty { return false }
        return x.isEmpty || x.contains(y) || y.contains(x)
    }
}
