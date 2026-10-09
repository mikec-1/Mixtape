// Speed, pitch, bass, reverb, stem levels and arrangement for song edits. One chain for the preview and the
// saved file, so what you hear is what you get:
// players (the song, or its stems) -> mix -> varispeed -> time pitch -> bass -> reverb -> out.

import AVFoundation
import Combine

/// How much disk a saved edit takes. Edits keep the quality they were saved at.
nonisolated enum EditQuality: String, CaseIterable, Identifiable, Sendable {
    case high, normal, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:   return "High"
        case .normal: return "Normal"
        case .low:    return "Low"
        }
    }

    var detail: String {
        switch self {
        case .high:   return "AAC 256 kbps, about 2 MB a minute."
        case .normal: return "AAC 128 kbps, about 1 MB a minute."
        case .low:    return "HE-AAC 64 kbps, about 0.5 MB a minute."
        }
    }

    var bitRate: Int {
        switch self {
        case .high:   return 256_000
        case .normal: return 128_000
        case .low:    return 64_000
        }
    }

    /// HE-AAC at 64k since plain AAC gets muddy below ~80k.
    var formatID: AudioFormatID { self == .low ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC }
}

nonisolated enum EditRenderer {

    struct RenderFailed: LocalizedError {
        var errorDescription: String? { "Couldn't render the edit." }
    }

    /// Reverb keeps ringing after the last sample; this much is kept so the echo isn't cut off.
    static let reverbTail: TimeInterval = 2
    static let outputRate: Double = 44_100

    /// Everything after the players, in order.
    nonisolated struct Chain {
        let mix = AVAudioMixerNode()
        let varispeed = AVAudioUnitVarispeed()
        let pitch = AVAudioUnitTimePitch()
        let bass = AVAudioUnitEQ(numberOfBands: 1)
        let reverb = AVAudioUnitReverb()
        /// Catches the peaks a bass boost pushes over full scale.
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        var nodes: [AVAudioNode] { [mix, varispeed, pitch, bass, reverb, limiter] }
    }

    /// Wires the chain for `format`. Players already in the engine are left where they are.
    static func build(_ engine: AVAudioEngine, players: [AVAudioPlayerNode], chain: Chain, format: AVAudioFormat) {
        for node in (players as [AVAudioNode]) + chain.nodes where node.engine == nil { engine.attach(node) }
        chain.reverb.loadFactoryPreset(.largeHall)
        let shelf = chain.bass.bands[0]
        shelf.filterType = .lowShelf
        shelf.frequency = 100
        shelf.bypass = false
        for (i, player) in players.enumerated() {
            engine.connect(player, to: chain.mix, fromBus: 0, toBus: i, format: format)
        }
        for (from, to) in zip(chain.nodes, chain.nodes.dropFirst()) { engine.connect(from, to: to, format: format) }
        engine.connect(chain.limiter, to: engine.mainMixerNode, format: format)
    }

    /// `levels` line up with the players.
    static func apply(_ edit: SongEdit, levels: [Double], players: [AVAudioPlayerNode], chain: Chain) {
        // Pitch set: stretch the time and keep that pitch. Unset: varispeed, so pitch follows speed.
        chain.varispeed.rate = edit.pitch == nil ? Float(edit.speed) : 1
        chain.pitch.bypass = edit.pitch == nil
        chain.pitch.rate = edit.pitch == nil ? 1 : Float(edit.speed)
        chain.pitch.pitch = Float((edit.pitch ?? 0) * 100)
        chain.bass.bypass = edit.bass < 0.005
        chain.bass.bands[0].gain = Float(edit.bass * 10)
        // Half the boost back off so the limiter only has to touch the loudest peaks.
        chain.bass.globalGain = Float(edit.bass * -5)
        chain.limiter.bypass = edit.bass < 0.005
        chain.reverb.wetDryMix = Float(edit.reverb * 60)
        for (player, level) in zip(players, levels) { player.volume = Float(level) }
    }

    typealias Piece = (start: AVAudioFramePosition, count: AVAudioFrameCount)

    /// Frame ranges of `file` in play order, loops unrolled. Nil sections is the whole file.
    static func pieces(of file: AVAudioFile, _ sections: [SongEdit.Section]?) -> [Piece] {
        guard let sections else { return [(0, AVAudioFrameCount(file.length))] }
        let rate = file.processingFormat.sampleRate
        return sections.flatMap { s -> [Piece] in
            let start = min(AVAudioFramePosition(s.start * rate), file.length)
            let end = min(AVAudioFramePosition(s.end * rate), file.length)
            return Array(repeating: (start, AVAudioFrameCount(max(end - start, 0))), count: s.times)
        }.filter { $0.count > 0 }
    }

    /// Queues `pieces` back to back on `player`, from `offset` frames into the arrangement. Where a piece
    /// jumps, its edge fades over 5 ms so the cut doesn't click. `done` runs once the last one has played.
    static func schedule(_ file: AVAudioFile, _ pieces: [Piece], from offset: AVAudioFramePosition,
                         on player: AVAudioPlayerNode, done: (@Sendable () -> Void)? = nil) {
        let fade = AVAudioFramePosition(file.processingFormat.sampleRate * 0.005)
        var parts: [(start: AVAudioFramePosition, count: AVAudioFramePosition, fadeIn: Bool?)] = []
        var skip = max(offset, 0)
        for (i, piece) in pieces.enumerated() {
            let count = AVAudioFramePosition(piece.count)
            if skip >= count { skip -= count; continue }
            let end = piece.start + count
            let joinedBefore = i > 0 ? pieces[i - 1].start + AVAudioFramePosition(pieces[i - 1].count) == piece.start
                : piece.start == 0
            let joinedAfter = i < pieces.count - 1 ? pieces[i + 1].start == end : end == file.length
            var start = piece.start + skip
            let half = (end - start) / 2
            let fadeIn = joinedBefore || skip > 0 ? 0 : min(fade, half)
            let fadeOut = joinedAfter ? 0 : min(fade, half)
            if fadeIn > 0 { parts.append((start, fadeIn, true)); start += fadeIn }
            parts.append((start, end - fadeOut - start, nil))
            if fadeOut > 0 { parts.append((end - fadeOut, fadeOut, false)) }
            skip = 0
        }
        parts.removeAll { $0.count <= 0 }
        // Its own reader, so the fades don't move the player's place in `file`. Loops reuse their fades.
        let reader = try? AVAudioFile(forReading: file.url)
        var made: [String: AVAudioPCMBuffer] = [:]
        for (i, part) in parts.enumerated() {
            var handler: AVAudioPlayerNodeCompletionHandler?
            if i == parts.count - 1, let done { handler = { _ in done() } }
            let key = "\(part.start) \(part.count) \(part.fadeIn ?? false)"
            if let fadeIn = part.fadeIn, let reader,
               let buffer = made[key] ?? faded(reader, from: part.start, count: part.count, in: fadeIn) {
                made[key] = buffer
                player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                      completionHandler: handler)
            } else {
                player.scheduleSegment(file, startingFrame: part.start, frameCount: AVAudioFrameCount(part.count),
                                       at: nil, completionCallbackType: .dataPlayedBack, completionHandler: handler)
            }
        }
    }

    /// `count` frames of `file` from `start`, rising from silence or falling to it.
    private static func faded(_ file: AVAudioFile, from start: AVAudioFramePosition, count: AVAudioFramePosition,
                              in fadeIn: Bool) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(count))) != nil,
              let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let n = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<n {
                let gain = Float(i) / Float(max(n - 1, 1))
                data[c][i] *= fadeIn ? gain : 1 - gain
            }
        }
        return buffer
    }

    /// What to play for `edit`: the song, or its stems at their levels. Separates on the first go.
    static func layers(for edit: SongEdit, source: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [(URL, Double)] {
        guard edit.stems != nil else { return [(source, 1)] }
        let stems = try await StemSeparator.stems(of: source, id: edit.of, progress: progress)
        return SongEdit.stemNames.compactMap { name in stems[name].map { ($0, edit.level(name)) } }
    }

    /// Writes the `layers` mixed, with the edit applied, to `dest` as AAC at `quality`. Faster than real
    /// time, off the main actor. `progress` gets 0-1, about once a percent.
    @concurrent static func render(_ layers: [(URL, Double)], edit: SongEdit,
                                   quality: EditQuality, to dest: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let inputs = try layers.map { try AVAudioFile(forReading: $0.0) }
        guard let input = inputs.first else { throw RenderFailed() }
        let engine = AVAudioEngine()
        let players = inputs.map { _ in AVAudioPlayerNode() }
        let chain = Chain()
        let speed = edit.speed, amount = edit.reverb
        build(engine, players: players, chain: chain, format: input.processingFormat)
        apply(edit, levels: layers.map(\.1), players: players, chain: chain)

        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else {
            throw RenderFailed()
        }
        try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        for (player, file) in zip(players, inputs) {
            schedule(file, pieces(of: file, edit.sections), from: 0, on: player)
            player.play()
        }

        let frames = pieces(of: input, edit.sections).reduce(0.0) { $0 + Double($1.count) }
        let seconds = frames / input.processingFormat.sampleRate / speed
            + (amount > 0 ? reverbTail : 0)
        let total = AVAudioFramePosition(seconds * outputRate)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw RenderFailed() }

        try? FileManager.default.removeItem(at: dest)
        // Scoped so the file is closed, and the AAC stream finished, before anyone reads it.
        do {
            let output = try AVAudioFile(forWriting: dest, settings: [
                AVFormatIDKey: quality.formatID,
                AVSampleRateKey: outputRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: quality.bitRate,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)

            var reported = 0
            while engine.manualRenderingSampleTime < total {
                try Task.checkCancellation()
                let frames = min(buffer.frameCapacity,
                                 AVAudioFrameCount(total - engine.manualRenderingSampleTime))
                switch try engine.renderOffline(frames, to: buffer) {
                case .success:
                    try output.write(from: buffer)
                case .error:
                    throw RenderFailed()
                default:
                    continue
                }
                let percent = Int(Double(engine.manualRenderingSampleTime) / Double(total) * 100)
                if percent > reported { reported = percent; progress(Double(percent) / 100) }
            }
        }
    }
}

/// Live preview for the editor. Its own engine, so main playback is only paused, not touched.
final class EditPreview: ObservableObject {

    @Published private(set) var isPlaying = false
    /// Seconds into the arrangement, before speed. Set freely while scrubbing, then `seek` to it.
    @Published var position: TimeInterval = 0
    /// The arrangement's length, before speed.
    @Published private(set) var duration: TimeInterval = 0
    /// The whole song's length.
    private(set) var length: TimeInterval = 0
    private var sections: [SongEdit.Section]?
    var isScrubbing = false
    /// The part playing over and over, by index. Seeking outside it ends the loop.
    @Published private(set) var looping: Int?
    /// That part's first frame in the arrangement, and how many frames it plays.
    private var loopSpan: (start: AVAudioFramePosition, count: AVAudioFramePosition)?

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private let chain = EditRenderer.Chain()
    private var files: [AVAudioFile] = []
    private var file: AVAudioFile? { files.first }
    private var startFrame: AVAudioFramePosition = 0
    /// Bumped on every stop, so a stopped segment's completion doesn't end the next one.
    private var generation = 0
    private var ticker: Task<Void, Never>?

    /// The song, or its stems. Swapping keeps the place; play again after.
    func load(_ urls: [URL]) throws {
        let files = try urls.map { try AVAudioFile(forReading: $0) }
        guard let first = files.first else { return }
        let at = position
        halt()
        engine.stop()
        for player in players { engine.detach(player) }
        players = files.map { _ in AVAudioPlayerNode() }
        self.files = files
        length = Double(first.length) / first.processingFormat.sampleRate
        EditRenderer.build(engine, players: players, chain: chain, format: first.processingFormat)
        arrange(sections, at: at)
    }

    /// Plays these parts in order. Nil is the whole song. Stops; play again after.
    func arrange(_ sections: [SongEdit.Section]?, at seconds: TimeInterval? = nil) {
        // The loop follows its part when others change or move, and ends when that part changes.
        let looped = looping.flatMap { i in self.sections.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        self.sections = sections
        guard let file else { return }
        halt()
        let rate = file.processingFormat.sampleRate
        duration = Double(EditRenderer.pieces(of: file, sections).reduce(0) { $0 + Int64($1.count) }) / rate
        let at = min(max(seconds ?? position, 0), duration)
        startFrame = AVAudioFramePosition(at * rate)
        position = at
        looping = looped.flatMap { sections?.firstIndex(of: $0) }
        loopSpan = looping.flatMap { span(of: $0) }
    }

    /// Plays part `index` over and over, from its start unless the playhead is already in it. Nil plays on.
    func loop(_ index: Int?) {
        guard let file else { return }
        let wasPlaying = isPlaying
        let at = currentFrame
        halt()
        loopSpan = index.flatMap { span(of: $0) }
        looping = loopSpan == nil ? nil : index
        startFrame = at
        if let loopSpan, !(loopSpan.start..<loopSpan.start + loopSpan.count).contains(at) { startFrame = loopSpan.start }
        position = Double(startFrame) / file.processingFormat.sampleRate
        if wasPlaying { play() }
    }

    /// Part `i`'s first frame in the arrangement and how many frames it plays.
    private func span(of i: Int) -> (start: AVAudioFramePosition, count: AVAudioFramePosition)? {
        guard let file, let sections, sections.indices.contains(i) else { return nil }
        func frames(_ parts: [SongEdit.Section]) -> AVAudioFramePosition {
            EditRenderer.pieces(of: file, parts).reduce(0) { $0 + AVAudioFramePosition($1.count) }
        }
        let count = frames([sections[i]])
        return count > 0 ? (frames(Array(sections.prefix(i))), count) : nil
    }

    /// Where the preview is now, in the arrangement, before speed.
    var now: TimeInterval {
        guard let file else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    /// `levels` line up with what was loaded.
    func apply(_ edit: SongEdit, levels: [Double] = [1]) {
        EditRenderer.apply(edit, levels: levels, players: players, chain: chain)
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let file, !isPlaying else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        if startFrame >= AVAudioFramePosition(duration * file.processingFormat.sampleRate) { startFrame = 0 }
        generation += 1
        let gen = generation
        if let loopSpan {
            if !(loopSpan.start..<loopSpan.start + loopSpan.count).contains(startFrame) { startFrame = loopSpan.start }
            for p in players.indices {
                queueLoop(p, from: startFrame - loopSpan.start, gen)
                queueLoop(p, from: 0, gen)
            }
        } else {
            for (player, f) in zip(players, files) {
                EditRenderer.schedule(f, EditRenderer.pieces(of: f, sections), from: startFrame, on: player) { [weak self] in
                    Task { @MainActor in self?.finished(gen) }
                }
            }
        }
        // One start time for every stem, so they can't drift a render cycle apart.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        for player in players { player.play(at: players.count > 1 ? start : nil) }
        isPlaying = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        startFrame = currentFrame
        halt()
        if let file { position = Double(startFrame) / file.processingFormat.sampleRate }
    }

    func seek(to seconds: TimeInterval) {
        guard let file else { return }
        let wasPlaying = isPlaying
        halt()
        let at = min(max(seconds, 0), duration)
        startFrame = AVAudioFramePosition(at * file.processingFormat.sampleRate)
        position = at
        if let loopSpan, !(loopSpan.start..<loopSpan.start + loopSpan.count).contains(startFrame) {
            looping = nil
            self.loopSpan = nil
        }
        if wasPlaying { play() }
    }

    func stop() {
        halt()
        engine.stop()
    }

    private var currentFrame: AVAudioFramePosition {
        guard let player = players.first, let now = player.lastRenderTime,
              let t = player.playerTime(forNodeTime: now) else { return startFrame }
        let frame = startFrame + max(t.sampleTime, 0)
        // A looping part comes round again.
        guard let loopSpan, frame >= loopSpan.start else { return frame }
        return loopSpan.start + (frame - loopSpan.start) % loopSpan.count
    }

    /// One pass of the looping part on player `p`. Each pass queues another as it ends, so one is always waiting.
    private func queueLoop(_ p: Int, from offset: AVAudioFramePosition, _ gen: Int) {
        guard let looping, let sections, sections.indices.contains(looping), files.indices.contains(p) else { return }
        let f = files[p]
        EditRenderer.schedule(f, EditRenderer.pieces(of: f, [sections[looping]]), from: offset, on: players[p]) { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.queueLoop(p, from: 0, gen)
            }
        }
    }

    private func tick() {
        guard isPlaying, !isScrubbing, let file else { return }
        position = Double(currentFrame) / file.processingFormat.sampleRate
    }

    private func halt() {
        generation += 1
        ticker?.cancel()
        for player in players { player.stop() }
        isPlaying = false
    }

    private func finished(_ gen: Int) {
        guard gen == generation else { return }
        halt()
        startFrame = 0
        position = 0
    }
}
