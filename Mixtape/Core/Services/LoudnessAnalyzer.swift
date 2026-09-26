// LoudnessAnalyzer.swift
// Mixtape — Core/Services
//
// Measures a file's integrated loudness (ITU-R BS.1770: K-weighted, gated) once
// and caches the answer, so playback can pull every song toward one level. The
// library is rips from a dozen sources with no shared mastering, so track-to-track
// level jumps are worse here than on any service that masters its own catalogue.
//
// Measuring is a full decode of the file, so it never happens on the main actor
// and never blocks a play: an unmeasured song starts at the library's typical
// correction and is measured in the background for next time.

import AVFoundation
import Foundation

public enum LoudnessAnalyzer {

    /// The level every song is pulled toward, in LUFS. Spotify's "normal".
    public nonisolated static let targetLUFS: Double = -14

    /// Where a measurement lives: an extended attribute on the audio file.
    ///
    /// Keyed to the file rather than to the track because the *file* is what was
    /// measured. A re-resolve ("wrong version") or a re-download replaces it, and
    /// the stale gain goes with it — which no track-keyed cache would get right
    /// without a hook on every path that can swap a file out.
    private nonisolated static let attribute = "tech.mixtaped.loudness.v1"

    /// Running average of the corrections measured so far, for anything with no
    /// measurement yet: a stream, or a file being measured right now. Starting
    /// those at unity instead would make the first second of every new song a
    /// step down.
    private nonisolated static let typicalKey = "playback.loudness.typicalGainDB"

    public nonisolated static var typicalGainDB: Float {
        UserDefaults.standard.object(forKey: typicalKey) as? Float ?? -5
    }

    // MARK: - Cache

    public nonisolated static func cachedGainDB(for url: URL) -> Float? {
        guard url.isFileURL else { return nil }
        var value: Float = 0
        let read = getxattr(url.path, attribute, &value, 4, 0, 0)
        guard read == 4, value.isFinite else { return nil }
        return value
    }

    private nonisolated static func cache(_ gain: Float, for url: URL) {
        var value = gain
        // A read-only source (a watched folder, the user's own Music folder) just
        // gets measured again next time; nothing here is worth an error path.
        _ = setxattr(url.path, attribute, &value, 4, 0, 0)

        let defaults = UserDefaults.standard
        let typical = defaults.object(forKey: typicalKey) as? Float ?? gain
        defaults.set(typical * 0.9 + gain * 0.1, forKey: typicalKey)
    }

    // MARK: - Measurement

    /// The correction for `url` in dB, measured if it hasn't been already.
    ///
    /// `@concurrent` keeps the decode off the main actor. Plain `nonisolated async` runs on the
    /// caller's actor with approachable concurrency on.
    @discardableResult
    @concurrent public nonisolated static func measureGainDB(for url: URL) async -> Float? {
        if let cached = cachedGainDB(for: url) { return cached }
        guard let measured = integrated(url) else { return nil }

        var gain = targetLUFS - measured.lufs
        // ReplayGain's clipping rule: a boost never takes the peak past -1 dBFS.
        if gain > 0 {
            let headroom = measured.peak > 0 ? -20 * log10(Double(measured.peak)) - 1 : 0
            gain = min(gain, max(0, headroom))
        }
        let clamped = Float(max(-24, min(12, gain)))
        cache(clamped, for: url)
        return clamped
    }

    /// Integrated loudness in LUFS plus the sample peak, or nil if the file can't
    /// be decoded. Blocks are the standard 400 ms with 75% overlap, built out of
    /// 100 ms bins so the whole file never has to be held in memory.
    private nonisolated static func integrated(_ url: URL) -> (lufs: Double, peak: Float)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = min(Int(format.channelCount), 2)   // L/R carry weight 1.0; ignore the rest
        let binFrames = Int(rate * 0.1)
        guard rate > 0, file.length > 0, channels > 0, binFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else { return nil }

        var filters = (0..<channels).map { _ in [Biquad.shelf(rate), Biquad.highPass(rate)] }
        var bins = [[Double]](repeating: [], count: channels)
        var sums = [Double](repeating: 0, count: channels)
        var inBin = 0
        var peak: Float = 0

        while file.framePosition < file.length {
            // AVAudioFile throws at the end of some files instead of returning a
            // zero-frame buffer, so a throw here is end-of-file, not a failure:
            // returning nil on it threw away every measurement.
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            for i in 0..<frames {
                for channel in 0..<channels {
                    let sample = data[channel][i]
                    peak = max(peak, abs(sample))
                    let weighted = filters[channel][1].process(filters[channel][0].process(Double(sample)))
                    sums[channel] += weighted * weighted
                }
                inBin += 1
                if inBin == binFrames {
                    for channel in 0..<channels { bins[channel].append(sums[channel]); sums[channel] = 0 }
                    inBin = 0
                }
            }
        }

        // Mean square per 400 ms block, summed across channels.
        let binCount = bins[0].count
        guard binCount >= 4 else { return nil }
        let window = Double(binFrames * 4)
        var blocks: [Double] = []
        blocks.reserveCapacity(binCount - 3)
        for start in 0...(binCount - 4) {
            var mean = 0.0
            for channel in 0..<channels {
                mean += (bins[channel][start] + bins[channel][start + 1]
                         + bins[channel][start + 2] + bins[channel][start + 3]) / window
            }
            blocks.append(mean)
        }

        // Two gates: absolute at -70 LUFS, then relative at 10 LU below the mean
        // of what survived — the part that stops a quiet intro or a long outro
        // from dragging the answer down.
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relative = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loudness($0) > relative }
        guard !kept.isEmpty else { return nil }
        return (loudness(kept.reduce(0, +) / Double(kept.count)), peak)
    }

    /// One second-order section. Two of them are BS.1770's K-weighting — a +4 dB
    /// high shelf and a 38 Hz high-pass — bilinear-transformed to the file's own
    /// sample rate rather than assuming the 48 kHz the spec tabulates.
    private nonisolated struct Biquad {
        let b0, b1, b2, a1, a2: Double
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        static func shelf(_ rate: Double) -> Biquad {
            let a = pow(10, 4.0 / 40)                       // +4 dB
            let w = 2 * Double.pi * 1_500 / rate
            let alpha = sin(w) / (2 * (1 / 2.0.squareRoot()))
            let cw = cos(w), sa = a.squareRoot()
            let a0 = (a + 1) - (a - 1) * cw + 2 * sa * alpha
            return Biquad(b0: a * ((a + 1) + (a - 1) * cw + 2 * sa * alpha) / a0,
                          b1: -2 * a * ((a - 1) + (a + 1) * cw) / a0,
                          b2: a * ((a + 1) + (a - 1) * cw - 2 * sa * alpha) / a0,
                          a1: 2 * ((a - 1) - (a + 1) * cw) / a0,
                          a2: ((a + 1) - (a - 1) * cw - 2 * sa * alpha) / a0)
        }

        static func highPass(_ rate: Double) -> Biquad {
            let w = 2 * Double.pi * 38 / rate
            let alpha = sin(w) / (2 * 0.5)
            let cw = cos(w)
            let a0 = 1 + alpha
            return Biquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0,
                          a1: -2 * cw / a0, a2: (1 - alpha) / a0)
        }
    }
}
