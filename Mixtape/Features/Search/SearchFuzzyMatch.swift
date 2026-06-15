// SearchFuzzyMatch.swift
// Mixtape — Features/Search
//
// Lightweight fuzzy matcher + relevance scoring used by SearchView so results
// rank the best matches first and tolerate typos / partial words. Pure value
// logic, no UIKit/SwiftUI — trivially testable and cheap on the filter path.

import Foundation

enum SearchFuzzyMatch {

    /// Returns a relevance score for `needle` against `haystack`, or `nil` when
    /// there is no reasonable match. Higher is better. Both inputs are expected
    /// to already be trimmed; casing is normalised here.
    ///
    /// Tiers (roughly): exact > prefix > word-boundary prefix > substring >
    /// subsequence (fuzzy). Shorter haystacks and earlier matches score higher.
    static func score(needle: String, in haystack: String) -> Int? {
        let n = needle.lowercased()
        let h = haystack.lowercased()
        guard !n.isEmpty else { return nil }
        guard !h.isEmpty else { return nil }

        // Exact
        if h == n { return 1000 }

        // Whole-string prefix
        if h.hasPrefix(n) {
            return 900 - min(h.count - n.count, 80)
        }

        // Word-boundary prefix (e.g. "dream" matches "Sweet Dreams")
        for word in h.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }) {
            if word.hasPrefix(n) {
                return 750 - min(word.count - n.count, 60)
            }
        }

        // Substring anywhere
        if let range = h.range(of: n) {
            let offset = h.distance(from: h.startIndex, to: range.lowerBound)
            return 600 - min(offset, 100)
        }

        // Subsequence (fuzzy) — every needle char appears in order. Penalise gaps
        // so tightly-clustered matches outrank scattered ones.
        if let gaps = subsequenceGaps(needle: n, in: h) {
            return max(120, 400 - gaps * 8 - h.count / 4)
        }

        return nil
    }

    /// Convenience: best score across several fields (e.g. title + artist).
    static func bestScore(needle: String, fields: [String]) -> Int? {
        var best: Int? = nil
        for field in fields {
            if let s = score(needle: needle, in: field) {
                if best == nil || s > best! { best = s }
            }
        }
        return best
    }

    /// Returns the total gap size if `needle` is an in-order subsequence of
    /// `haystack`, else nil. A gap is the number of skipped haystack chars
    /// between consecutive needle matches.
    private static func subsequenceGaps(needle n: String, in h: String) -> Int? {
        var gaps = 0
        var sinceLast = 0
        var matchedAny = false
        var ni = n.startIndex
        for ch in h {
            if ni < n.endIndex, ch == n[ni] {
                if matchedAny { gaps += sinceLast }
                sinceLast = 0
                matchedAny = true
                ni = n.index(after: ni)
                if ni == n.endIndex { return gaps }
            } else {
                sinceLast += 1
            }
        }
        return ni == n.endIndex ? gaps : nil
    }
}
