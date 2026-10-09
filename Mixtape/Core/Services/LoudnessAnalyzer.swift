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
    private nonisolated static let beatsAttribute = "tech.mixtaped.beats.v1"

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

    /// Beat grids near each end of a song, in seconds, and how strongly it repeats at its tempo (0 to 1).
    /// `introBeat` is the first beat after the sound starts; `outroBeat` is any beat near the end.
    public nonisolated struct Beats {
        public let introPeriod, introBeat, outroPeriod, outroBeat, strength: Double
        static let unclear = Beats(introPeriod: 0, introBeat: 0, outroPeriod: 0, outroBeat: 0, strength: 0)
    }

    public nonisolated static func cachedBeats(for url: URL) -> Beats? {
        guard url.isFileURL else { return nil }
        var v = [Float](repeating: 0, count: 5)
        let read = getxattr(url.path, beatsAttribute, &v, 20, 0, 0)
        guard read == 20, v.allSatisfy(\.isFinite) else { return nil }
        return Beats(introPeriod: Double(v[0]), introBeat: Double(v[1]), outroPeriod: Double(v[2]),
                     outroBeat: Double(v[3]), strength: Double(v[4]))
    }

    private nonisolated static func cache(_ gain: Float, edges: (start: Double, end: Double, out: Double),
                                          beats: Beats, for url: URL) {
        var value = gain
        // Read-only files are just measured again next time.
        _ = setxattr(url.path, attribute, &value, 4, 0, 0)
        var values = [Float(edges.start), Float(edges.end), Float(edges.out)]
        _ = setxattr(url.path, edgesAttribute, &values, 12, 0, 0)
        var grid = [beats.introPeriod, beats.introBeat, beats.outroPeriod, beats.outroBeat, beats.strength].map(Float.init)
        _ = setxattr(url.path, beatsAttribute, &grid, 20, 0, 0)

        let defaults = UserDefaults.standard
        let typical = defaults.object(forKey: typicalKey) as? Float ?? gain
        defaults.set(typical * 0.9 + gain * 0.1, forKey: typicalKey)
    }

    // MARK: - Measurement

    /// Gain for `url` in dB, measuring if needed. `@concurrent` keeps the decode off the main
    /// actor; plain nonisolated async runs on the caller's.
    @discardableResult
    @concurrent public nonisolated static func measureGainDB(for url: URL) async -> Float? {
        if let cached = cachedGainDB(for: url), cachedEdges(for: url) != nil, cachedBeats(for: url) != nil {
            return cached
        }
        guard let measured = integrated(url) else { return nil }

        var gain = targetLUFS - measured.lufs
        // ReplayGain's clipping rule: a boost never takes the peak past -1 dBFS.
        if gain > 0 {
            let headroom = measured.peak > 0 ? -20 * log10(Double(measured.peak)) - 1 : 0
            gain = min(gain, max(0, headroom))
        }
        let clamped = Float(max(-24, min(12, gain)))
        cache(clamped, edges: measured.edges, beats: measured.beats, for: url)
        return clamped
    }

    /// Integrated LUFS and sample peak. 400 ms blocks with 75% overlap, built
    /// from 100 ms bins so the file isn't held in memory.
    private nonisolated static func integrated(_ url: URL)
        -> (lufs: Double, peak: Float, edges: (start: Double, end: Double, out: Double), beats: Beats)? {
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
        // Raw energy every ~11.6 ms for the beat grid.
        let hopFrames = max(1, Int((rate * 0.0116).rounded()))
        var energies: [Double] = []
        var energy = 0.0, inHop = 0

        while file.framePosition < file.length {
            // Some files throw at the end instead of returning zero frames.
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            for i in 0..<frames {
                var mono: Float = 0
                for channel in 0..<channels {
                    let sample = data[channel][i]
                    mono += sample
                    peak = max(peak, abs(sample))
                    let weighted = filters[channel][1].process(filters[channel][0].process(Double(sample)))
                    sums[channel] += weighted * weighted
                }
                energy += Double(mono * mono)
                inHop += 1
                if inHop == hopFrames { energies.append(energy); energy = 0; inHop = 0 }
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
        let beats = beatGrid(energies, hop: Double(hopFrames) / rate, start: edges.start, end: edges.end)
        return (lufs, peak, edges, beats)
    }

    // MARK: - Beats

    /// Tempo from the autocorrelation of the onset envelope, then a beat grid fitted near each end.
    private nonisolated static func beatGrid(_ energies: [Double], hop: Double, start: Double, end: Double) -> Beats {
        guard energies.count > Int(20 / hop) else { return .unclear }
        let env = onsets(energies)
        guard let tempo = tempo(env, hop: hop) else { return .unclear }
        let intro = grid(env, period: tempo.period, from: start / hop, to: start / hop + 20 / hop)
        let outro = grid(env, period: tempo.period, from: max(start, end - 30) / hop, to: end / hop)
        return Beats(introPeriod: intro.period * hop, introBeat: intro.first * hop,
                     outroPeriod: outro.period * hop, outroBeat: outro.first * hop, strength: tempo.strength)
    }

    /// Every beat in the song, in seconds, from energies `hop` seconds apart. The grid is fitted again every
    /// 8 seconds so a song that drifts off a click still lines up. Empty without a steady beat.
    nonisolated static func beatTimes(_ energies: [Double], hop: Double) -> [Double] {
        guard energies.count > Int(20 / hop) else { return [] }
        let env = onsets(energies)
        // ponytail: same 0.12 floor as beat matching.
        guard let tempo = tempo(env, hop: hop), tempo.strength > 0.12 else { return [] }
        let window = 8 / hop, last = Double(env.count - 1)
        var beats: [Double] = []
        var from = 0.0
        while from < last {
            let fit = grid(env, period: tempo.period, from: from, to: from + window)
            var t = fit.first
            while t < min(from + window, last) {
                // Neighbouring windows can land a hair apart at the seam.
                if beats.last.map({ t * hop - $0 > fit.period * hop / 2 }) ?? true { beats.append(t * hop) }
                t += fit.period
            }
            from += window
        }
        return beats
    }

    /// Onset strength: the rise in log energy from one hop to the next.
    private nonisolated static func onsets(_ energies: [Double]) -> [Double] {
        var env = [Double](repeating: 0, count: energies.count)
        for i in 1..<max(energies.count, 1) { env[i] = max(0, log(energies[i] + 1e-9) - log(energies[i - 1] + 1e-9)) }
        return env
    }

    /// The beat period in hops, from the autocorrelation of the onsets, and how strongly it repeats (0 to 1).
    private nonisolated static func tempo(_ env: [Double], hop: Double) -> (period: Double, strength: Double)? {
        let mean = env.reduce(0, +) / Double(max(env.count, 1))
        let x = env.map { $0 - mean }
        func ac(_ lag: Int) -> Double {
            var sum = 0.0
            for i in lag..<x.count { sum += x[i] * x[i - lag] }
            return sum
        }
        let minLag = Int(60 / 200 / hop), maxLag = Int(60 / 60 / hop) + 1
        let zero = ac(0)
        guard zero > 0, minLag > 1, maxLag + 1 < x.count else { return nil }
        var values = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) { values[lag] = ac(lag) }
        // Leans toward 120 BPM so half or double time doesn't win on a technicality.
        func score(_ lag: Int) -> Double { values[lag] * exp(-0.5 * pow(log2(60 / (Double(lag) * hop) / 120), 2)) }
        let best = (minLag...maxLag).max { score($0) < score($1) } ?? minLag
        let a = values[best - 1], b = values[best], c = values[best + 1]
        let bend = a - 2 * b + c
        return (Double(best) + (bend == 0 ? 0 : max(-0.5, min(0.5, 0.5 * (a - c) / bend))), b / zero)
    }

    /// The comb within 2% of `period` (in hops) that lands on the most onset in [from, to), and its first tooth.
    private nonisolated static func grid(_ env: [Double], period: Double, from: Double, to: Double)
        -> (period: Double, first: Double) {
        func at(_ x: Double) -> Double {
            let i = Int(x)
            guard i >= 0, i + 1 < env.count else { return 0 }
            return env[i] + (env[i + 1] - env[i]) * (x - Double(i))
        }
        let end = min(to, Double(env.count - 1))
        var best = (period: period, first: from), bestScore = -1.0
        var p = period * 0.98
        while p <= period * 1.02 {
            var phase = 0.0
            while phase < p {
                var sum = 0.0, t = from + phase
                while t < end { sum += at(t); t += p }
                if sum > bestScore { bestScore = sum; best = (p, from + phase) }
                phase += 0.25
            }
            p += 0.01
        }
        return best
    }

    /// When the next song should start, in the current song's seconds, so their beats meet at the middle of
    /// the fade where both are equally loud. Nil when either tempo is unclear or they don't match.
    public nonisolated static func alignedStart(out: Beats, into: Beats, leadIn: Double, near start: Double,
                                                after earliest: Double, fade: Double) -> Double? {
        // ponytail: fixed floors (0.12 strength, 2% tempo gap, no stretching). Tune by ear.
        guard out.strength > 0.12, into.strength > 0.12, out.outroPeriod > 0, into.introPeriod > 0 else { return nil }
        // Half or double time still lines up.
        var ratio = into.introPeriod / out.outroPeriod
        while ratio > 2.squareRoot() { ratio /= 2 }
        while ratio < 1 / 2.squareRoot() { ratio *= 2 }
        guard abs(ratio - 1) < 0.02 else { return nil }
        // The incoming beat nearest the middle of the fade, counted from where it starts playing.
        let first = max(0, into.introBeat - leadIn)
        let offset = first + max(0, ((fade / 2 - first) / into.introPeriod).rounded()) * into.introPeriod
        // The outgoing beat it lands on: nearest the planned start, but late enough to schedule.
        var k = ((start + offset - out.outroBeat) / out.outroPeriod).rounded()
        while out.outroBeat + k * out.outroPeriod - offset < earliest { k += 1 }
        return out.outroBeat + k * out.outroPeriod - offset
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
