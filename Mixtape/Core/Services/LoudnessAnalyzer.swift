// Measures integrated loudness (BS.1770, K-weighted and gated) once and caches
// it, so playback can level songs from different sources. Decoding is slow, so
// it runs off the main actor and unmeasured songs start at the typical gain.

import AVFoundation
import Foundation

public enum LoudnessAnalyzer {

    /// The level every song is pulled toward, in LUFS. Spotify's "normal".
    public nonisolated static let targetLUFS: Double = -14

    /// Stored as an xattr on the file, so replacing the file drops a stale value.
    private nonisolated static let attribute = "tech.mixtaped.loudness.v1"
    private nonisolated static let edgesAttribute = "tech.mixtaped.edges.v1"

    /// Running average gain, used before a song is measured.
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

    /// Seconds into the file where the sound starts and stops, and where the ending
    /// drops well below the song's level. Measured with the gain.
    public nonisolated static func cachedEdges(for url: URL) -> (start: Double, end: Double, out: Double)? {
        guard url.isFileURL else { return nil }
        var values = [Float](repeating: 0, count: 3)
        let read = getxattr(url.path, edgesAttribute, &values, 12, 0, 0)
        guard read == 12, values.allSatisfy(\.isFinite) else { return nil }
        return (Double(values[0]), Double(values[1]), Double(values[2]))
    }

    private nonisolated static func cache(_ gain: Float, edges: (start: Double, end: Double, out: Double),
                                          for url: URL) {
        var value = gain
        // Read-only files are just measured again next time.
        _ = setxattr(url.path, attribute, &value, 4, 0, 0)
        var values = [Float(edges.start), Float(edges.end), Float(edges.out)]
        _ = setxattr(url.path, edgesAttribute, &values, 12, 0, 0)

        let defaults = UserDefaults.standard
        let typical = defaults.object(forKey: typicalKey) as? Float ?? gain
        defaults.set(typical * 0.9 + gain * 0.1, forKey: typicalKey)
    }

    // MARK: - Measurement

    /// Gain for `url` in dB, measuring if needed. `@concurrent` keeps the decode off the main
    /// actor; plain nonisolated async runs on the caller's.
    @discardableResult
    @concurrent public nonisolated static func measureGainDB(for url: URL) async -> Float? {
        if let cached = cachedGainDB(for: url), cachedEdges(for: url) != nil { return cached }
        guard let measured = integrated(url) else { return nil }

        var gain = targetLUFS - measured.lufs
        // ReplayGain's clipping rule: a boost never takes the peak past -1 dBFS.
        if gain > 0 {
            let headroom = measured.peak > 0 ? -20 * log10(Double(measured.peak)) - 1 : 0
            gain = min(gain, max(0, headroom))
        }
        let clamped = Float(max(-24, min(12, gain)))
        cache(clamped, edges: measured.edges, for: url)
        return clamped
    }

    /// Integrated LUFS and sample peak. 400 ms blocks with 75% overlap, built
    /// from 100 ms bins so the file isn't held in memory.
    private nonisolated static func integrated(_ url: URL)
        -> (lufs: Double, peak: Float, edges: (start: Double, end: Double, out: Double))? {
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
            // Some files throw at the end instead of returning zero frames.
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

        // Absolute gate at -70 LUFS, then relative 10 LU below the mean.
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relative = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loudness($0) > relative }
        guard !kept.isEmpty else { return nil }
        let lufs = loudness(kept.reduce(0, +) / Double(kept.count))

        // ponytail: fixed thresholds (35 LU down is silence, 10 LU down is an outro). Tune here if fades land wrong.
        let hop = Double(binFrames) / rate
        let silence = max(-60, lufs - 35)
        let first = blocks.firstIndex { $0 > 0 && loudness($0) > silence } ?? 0
        let last = blocks.lastIndex { $0 > 0 && loudness($0) > silence } ?? blocks.count - 1
        let loud = blocks.lastIndex { $0 > 0 && loudness($0) > lufs - 10 } ?? last
        let edges = (start: Double(first) * hop, end: Double(last + 4) * hop, out: Double(loud + 4) * hop)
        return (lufs, peak, edges)
    }

    /// One biquad. Two make up K-weighting (+4 dB shelf and 38 Hz high-pass),
    /// computed for the file's own sample rate.
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
