// Shared timing for synced lyrics: per-word spans and instrumental gaps.

import Foundation

public enum LyricSync {
    /// Offset for the word sweep. Output latency may need trimming.
    public static let sweepOffset: TimeInterval = 0

    /// Word timings per line. Word-timed sources (Apple TTML) pass straight through.
    /// Line-timed ones (LRCLIB, NetEase) are split by word length.
    /// Mirrors interpolateWords in the web client's lyrics.ts.
    public static func words(for lines: [LyricLine]) -> [[LyricWord]] {
        lines.enumerated().map { index, line in
            line.words ?? split(line, nextTime: index + 1 < lines.count ? lines[index + 1].time : nil)
        }
    }

    private static let minWord: TimeInterval = 0.09
    /// Seconds per character, used to cap a line that's followed by a long gap.
    private static let secondsPerChar: TimeInterval = 0.14

    private static func split(_ line: LyricLine, nextTime: TimeInterval?) -> [LyricWord] {
        let texts = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !texts.isEmpty else { return [] }

        // Don't sweep through an instrumental break.
        let plausible = line.time + max(0.8, Double(line.text.count) * secondsPerChar)
        let end = max(line.time + Double(texts.count) * minWord, min(nextTime ?? plausible, plausible))

        let weights = texts.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        let span = end - line.time

        var cursor = line.time
        return texts.enumerated().map { index, text in
            let start = cursor
            cursor = index == texts.count - 1 ? end : start + max(minWord, (weights[index] / total) * span)
            return LyricWord(time: start, end: cursor, text: text)
        }
    }

    /// The instrumental gap before `index` if it's long enough to mark.
    public static func instrumentalGap(before index: Int,
                                       lines: [LyricLine],
                                       words: [[LyricWord]]) -> (start: TimeInterval, end: TimeInterval)? {
        guard index < lines.count else { return nil }
        let start: TimeInterval
        if index == 0 {
            start = 0
        } else if index - 1 < words.count, let last = words[index - 1].last {
            start = last.end
        } else {
            start = lines[index - 1].time
        }
        let end = lines[index].time
        // Seven seconds, same as am-lyrics.
        return end - start >= 7 ? (start, end) : nil
    }
}
