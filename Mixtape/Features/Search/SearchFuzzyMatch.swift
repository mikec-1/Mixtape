// Fuzzy matching and relevance scoring for SearchView. Pure logic, no UI.

import Foundation

nonisolated enum SearchFuzzyMatch {

    /// Relevance of `needle` in `haystack`, nil for no match. Higher is better; inputs pre-trimmed.
    /// Exact > prefix > word prefix > substring > subsequence. Shorter and earlier scores higher.
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

        // Subsequence: every needle char in order, penalised by gaps.
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

    /// Total skipped chars if `needle` is an in-order subsequence of `haystack`, else nil.
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
