// LyricSync.swift
// Mixtape — Core/Services
//
// Shared tuning for synced-lyric highlighting: per-word spans so the highlight
// sweeps through a line instead of flipping it on whole, and the instrumental
// gaps worth marking with dots.

import Foundation

public enum LyricSync {
    /// Offset for the *word sweep*, as opposed to picking the line.
    ///
    /// The sweep wants the real position, which `interpolatedTime()` already
    /// carries forward between the clock's 5Hz ticks. Left as a knob because
    /// output latency is a physical thing and may want trimming.
    public static let sweepOffset: TimeInterval = 0

    /// Per-word start/end times for every line.
    ///
    /// A word-timed source (Apple's TTML) fills `words` itself and is passed
    /// straight through — that's the real thing, where a held note holds for
    /// exactly as long as it's held. The rest are *estimated*: LRCLIB and
    /// NetEase both only stamp the moment a line starts, so within a line the
    /// span is shared out by word length (plus one, so "a" still gets a beat of
    /// its own). Mirrors `interpolateWords` in the web client's `lyrics.ts`.
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

        // A line sung right before an instrumental break must not keep sweeping
        // through it, so the end is capped by what the line could plausibly take.
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

    /// The instrumental gap before `index`, if it's long enough to be worth
    /// marking. Nil otherwise — most line-to-line gaps are a breath, not a break.
    ///
    /// The gap runs from the end of the previous line (its last word's end,
    /// which for an estimated line is where the sweep stops) to the start of
    /// this one. Before the first line, from the top of the song.
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
        // `am-lyrics`' own threshold: seven seconds of nothing is an
        // instrumental, less than that is just space between lines.
        return end - start >= 7 ? (start, end) : nil
    }
}
