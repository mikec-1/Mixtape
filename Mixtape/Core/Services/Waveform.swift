// The shape of a song, SoundCloud style: the loudness (RMS) of even slices, loudest slice = 1.
// Peaks would pin a loud master flat at the top. Posts store 500 slices as base64 bytes; the
// studio works from a finer set.

import Accelerate
import AVFoundation

enum Waveform {
    /// Slices a post keeps. Views squeeze or stretch them to fit. Changing it redraws every post
    /// on its owner's next launch.
    static let postSlices = 500

    /// Loudness of `url` in `count` even slices, 0...1 unless `raw`. Nil if it can't be read.
    @concurrent static func peaks(of url: URL, count: Int, raw: Bool = false) async -> [Float]? {
        guard count > 0, let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)
        else { return nil }
        let per = max(Int(file.length) / count, 1)
        let channels = Int(file.processingFormat.channelCount)
        var power = [Float](repeating: 0, count: count)
        var frames = [Int](repeating: 0, count: count)
        var position = 0
        while file.framePosition < file.length {
            if Task.isCancelled { return nil }
            // Some files throw at the end instead of returning zero frames.
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            var i = 0
            while i < n {
                let slot = min((position + i) / per, count - 1)
                let end = slot == count - 1 ? n : min(n, (slot + 1) * per - position)
                for c in 0..<channels {
                    power[slot] += vDSP.sumOfSquares(UnsafeBufferPointer(start: data[c] + i, count: end - i))
                }
                frames[slot] += (end - i) * channels
                i = end
            }
            position += n
        }
        let level = (0..<count).map { frames[$0] > 0 ? (power[$0] / Float(frames[$0])).squareRoot() : 0 }
        guard !raw, let loudest = level.max(), loudest > 0 else { return level }
        return level.map { $0 / loudest }
    }

    /// Each stem's peaks, scaled together so all of them at full read as the song.
    @concurrent static func stems(_ files: [String: URL], count: Int) async -> [String: [Float]]? {
        var out: [String: [Float]] = [:]
        for (name, url) in files {
            guard let p = await peaks(of: url, count: count, raw: true) else { return nil }
            out[name] = p
        }
        let loudest = (0..<count).map { i in out.values.reduce(0) { $0 + $1[i] * $1[i] }.squareRoot() }.max() ?? 0
        guard loudest > 0 else { return out }
        return out.mapValues { $0.map { $0 / loudest } }
    }

    /// The song's shape with each stem at its level. Stems add as power, like unrelated sounds do.
    static func mixed(_ stems: [String: [Float]], levels: [String: Double]) -> [Float] {
        var out = [Float](repeating: 0, count: stems.values.first?.count ?? 0)
        for (name, p) in stems {
            let level = Float(levels[name] ?? 1)
            for i in out.indices { out[i] += p[i] * p[i] * level * level }
        }
        return out.map { min($0.squareRoot(), 1) }
    }

    /// The peaks of `sections` played back to back, from peaks of the whole song.
    static func arranged(_ peaks: [Float], length: Double, _ sections: [SongEdit.Section]?) -> [Float] {
        guard let sections, length > 0, !peaks.isEmpty else { return peaks }
        let per = Double(peaks.count) / length
        return sections.flatMap { part -> [Float] in
            let a = min(Int(part.start * per), peaks.count - 1)
            let b = min(max(Int(part.end * per), a + 1), peaks.count)
            return Array(repeating: peaks[a..<b], count: part.times).flatMap { $0 }
        }
    }

    /// `peaks` squeezed (averaged) or stretched (nearest) to `count` bars.
    static func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        let step = Double(peaks.count) / Double(count)
        return (0..<count).map { i in
            let a = min(Int(Double(i) * step), peaks.count - 1)
            let b = max(min(Int(Double(i + 1) * step), peaks.count), a + 1)
            return peaks[a..<b].reduce(0, +) / Float(b - a)
        }
    }

    static func encode(_ peaks: [Float]) -> String {
        Data(resample(peaks, to: postSlices).map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
            .base64EncodedString()
    }

    static func decode(_ text: String?) -> [Float]? {
        guard let text, let data = Data(base64Encoded: text), !data.isEmpty else { return nil }
        return data.map { Float($0) / 255 }
    }
}
