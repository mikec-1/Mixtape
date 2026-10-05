// Checks LoudnessAnalyzer's BS.1770 maths against the real source file:
//
//   xcrun swiftc Mixtape/Core/Services/LoudnessAnalyzer.swift \
//       scripts/loudness-check.swift -o /tmp/loudcheck && /tmp/loudcheck
//
// EBU Tech 3341: a 997 Hz stereo sine at X dBFS reads X LUFS; the gates keep a
// silent tail from dragging it down. Click tracks check the beat grid and that a
// beat-matched crossfade puts a beat on a beat.

import AVFoundation

@main
struct LoudnessCheck {

    static func makeFile(_ name: String, peakDB: Double, seconds: Double, silenceTail: Double = 0) throws -> URL {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let amp = Float(pow(10.0, peakDB / 20))
        let total = Int((seconds + silenceTail) * 48_000)
        let tone  = Int(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<total {
                samples[i] = i < tone ? amp * Float(sin(2 * Double.pi * 997 * Double(i) / 48_000)) : 0
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Clicks at `bpm` from `first` seconds, over a quiet tone that starts with them.
    static func clicks(_ name: String, bpm: Double, first: Double) throws -> URL {
        let rate = 44_100.0, total = Int(40 * rate)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            let t = Double(i) / rate, since = (t - first).truncatingRemainder(dividingBy: 60 / bpm)
            let v = t < first ? 0 : since < 0.03 ? 0.5 * sin(2 * .pi * 1000 * t) * exp(-since * 100) : 0.02 * sin(2 * .pi * 220 * t)
            buffer.floatChannelData![0][i] = Float(v)
            buffer.floatChannelData![1][i] = Float(v)
        }
        try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buffer)
        return url
    }

    static func lufs(_ url: URL) async -> Double {
        guard let gain = await LoudnessAnalyzer.measureGainDB(for: url) else {
            fatalError("no measurement for \(url.lastPathComponent)")
        }
        return LoudnessAnalyzer.targetLUFS - Double(gain)
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        let quiet = try makeFile("quiet", peakDB: -14, seconds: 20)
        let loud  = try makeFile("loud",  peakDB:  -8, seconds: 20)
        let tail  = try makeFile("tail",  peakDB:  -8, seconds: 10, silenceTail: 10)
        defer { for u in [quiet, loud, tail] { try? FileManager.default.removeItem(at: u) } }

        let q = await lufs(quiet), l = await lufs(loud), t = await lufs(tail)
        print(String(format: "tone -14 dBFS -> %.2f LUFS", q))
        print(String(format: "tone  -8 dBFS -> %.2f LUFS", l))
        print(String(format: "half silence  -> %.2f LUFS", t))

        assert(abs(q + 14) < 0.4, "absolute calibration off: \(q)")
        assert(abs(l + 8) < 0.4, "absolute calibration off: \(l)")
        assert(abs((q - l) + 6) < 0.1, "scaling off: \(q - l)")
        assert(abs(t - l) < 0.4, "gating off: \(t) vs \(l)")
        let edges = LoudnessAnalyzer.cachedEdges(for: tail)!
        assert(edges.start < 0.2 && abs(edges.end - 10) < 0.6, "edges off: \(edges)")

        let a = try clicks("a", bpm: 128, first: 1), b = try clicks("b", bpm: 126.5, first: 2)
        let c = try clicks("c", bpm: 120, first: 1)
        defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }
        for u in [a, b, c] { await LoudnessAnalyzer.measureGainDB(for: u) }
        let ba = LoudnessAnalyzer.cachedBeats(for: a)!, bb = LoudnessAnalyzer.cachedBeats(for: b)!
        let bc = LoudnessAnalyzer.cachedBeats(for: c)!
        let pa = 60 / 128.0, pb = 60 / 126.5
        let leadIn = LoudnessAnalyzer.cachedEdges(for: b)!.start
        print(String(format: "clicks 128 -> %.2f BPM, first beat %.3fs", 60 / ba.introPeriod, ba.introBeat))
        assert(abs(ba.introPeriod / pa - 1) < 0.003 && abs(ba.outroPeriod / pa - 1) < 0.003, "tempo off")
        assert(abs(bb.introPeriod / pb - 1) < 0.003, "tempo off")
        assert(abs(ba.introBeat - 1) < 0.02 && abs(bb.introBeat - 2) < 0.02, "first beat off")

        let start = LoudnessAnalyzer.alignedStart(out: ba, into: bb, leadIn: leadIn, near: 30, after: 29, fade: 6)!
        // b's true beats in a's seconds: the one nearest mid-fade should sit on one of a's.
        let mid = (0..<40).map { start + (2 - leadIn) + Double($0) * pb }.min { abs($0 - start - 3) < abs($1 - start - 3) }!
        let miss = abs((mid - 1) / pa - ((mid - 1) / pa).rounded()) * pa
        print(String(format: "128 into 126.5 -> beats meet within %.1f ms", miss * 1000))
        assert(start >= 29 && abs(start - 30) < pa, "start strays from the plan: \(start)")
        assert(miss < 0.015, "beats miss by \(miss)s")
        assert(LoudnessAnalyzer.alignedStart(out: ba, into: bc, leadIn: 1, near: 30, after: 29, fade: 6) == nil,
               "128 and 120 shouldn't match")
        print("ok")
    }
}
