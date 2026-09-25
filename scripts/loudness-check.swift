// loudness-check.swift
// Mixtape — scripts
//
// The one check on LoudnessAnalyzer's BS.1770 maths. There is no test target, so
// this compiles standalone against the real source file:
//
//   xcrun swiftc -O Mixtape/Core/Services/LoudnessAnalyzer.swift \
//       scripts/loudness-check.swift -o /tmp/loudcheck && /tmp/loudcheck
//
// EBU Tech 3341: a 997 Hz stereo sine of peak X dBFS must read X LUFS, and a
// silent tail must not drag the answer down (that's what the gates are for).

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
        print("ok")
    }
}
