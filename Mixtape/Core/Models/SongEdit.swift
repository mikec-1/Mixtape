// What an edited song is made from. Stored with the edit so it can be remade later.

import Foundation

public nonisolated struct SongEdit: Codable, Hashable, Sendable {
    /// The original song.
    public var of: UUID
    /// "title|artist", to find the original in another library.
    public var sourceRef: String
    /// 0.5...1.5, pitch follows unless `pitch` is set.
    public var speed: Double
    /// Semitones from the original, -12...12, whatever the speed. Nil follows the speed.
    public var pitch: Double?
    /// Low-shelf boost, 0...1.
    public var bass: Double
    /// 0...1.
    public var reverb: Double
    /// Mac studio: each stem's level, 0...1, by name in `stemNames`. Nil is the whole song as it is.
    /// A studio edit can't be rebuilt from its recipe on every device, so its file is uploaded.
    public var stems: [String: Double]?
    /// Parts of the original in play order, each looped `times`. Nil is the song start to end.
    /// One part played once is a trim, which any device can make. More is the Mac studio's.
    public var sections: [Section]?

    public static let speedRange: ClosedRange<Double> = 0.5...1.5
    public static let pitchRange: ClosedRange<Double> = -12...12
    /// What the separator makes, in the order the editor lists them.
    public static let stemNames = ["vocals", "drums", "bass", "other"]

    public static let maxSections = 24
    public static let maxLoops = 8

    /// Arranging needs the Mac studio.
    public static var canArrange: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public struct Section: Codable, Hashable, Sendable {
        /// Seconds into the original.
        public var start: Double
        public var end: Double
        public var times: Int

        public init(start: Double, end: Double, times: Int = 1) {
            self.start = start
            self.end = end
            self.times = times
        }

        public var length: Double { end - start }
        /// How long it plays, loops included.
        public var span: Double { length * Double(times) }
    }

    public init(of: UUID, sourceRef: String, speed: Double, reverb: Double, pitch: Double? = nil, bass: Double = 0,
                stems: [String: Double]? = nil, sections: [Section]? = nil) {
        self.of = of
        self.sourceRef = sourceRef
        self.speed = speed.clamped(to: Self.speedRange)
        self.reverb = reverb.clamped(to: 0...1)
        self.pitch = pitch.map { ($0.clamped(to: Self.pitchRange) * 100).rounded() / 100 }
        self.bass = bass.clamped(to: 0...1)
        let levels = stems.map { given in
            Dictionary(uniqueKeysWithValues: Self.stemNames.map { ($0, (given[$0] ?? 1).clamped(to: 0...1)) })
        }
        // All up full is the plain song.
        self.stems = levels?.values.allSatisfy({ $0 > 0.995 }) == true ? nil : levels
        // Hundredths keep the recipe small (the column caps at 4 KB) and compare cleanly.
        let parts = sections?.prefix(Self.maxSections).compactMap { s -> Section? in
            let start = ((s.start.isFinite ? max(s.start, 0) : 0) * 100).rounded() / 100
            let end = ((s.end.isFinite ? s.end : 0) * 100).rounded() / 100
            guard end - start >= 0.05 else { return nil }
            return Section(start: start, end: end, times: min(max(s.times, 1), Self.maxLoops))
        }
        self.sections = parts?.isEmpty == false ? parts : nil
    }

    enum CodingKeys: String, CodingKey {
        case of, speed, pitch, bass, reverb, stems, sections
        case sourceRef = "source_ref"
    }

    // Lenient so fields added later don't break older builds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(of: try c.decode(UUID.self, forKey: .of),
                  sourceRef: try c.decodeIfPresent(String.self, forKey: .sourceRef) ?? "",
                  speed: try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1,
                  reverb: try c.decodeIfPresent(Double.self, forKey: .reverb) ?? 0,
                  pitch: try? c.decodeIfPresent(Double.self, forKey: .pitch),
                  bass: (try? c.decodeIfPresent(Double.self, forKey: .bass)) ?? 0,
                  stems: try? c.decodeIfPresent([String: Double].self, forKey: .stems),
                  sections: try? c.decodeIfPresent([Section].self, forKey: .sections))
    }

    public var isOriginal: Bool {
        abs(speed - 1) < 0.005 && abs(pitch ?? 0) < 0.005 && bass < 0.005 && reverb < 0.005
            && stems == nil && sections == nil
    }
    /// More than a trim: needs the Mac studio to remake.
    public var isArranged: Bool { sections.map { $0.count > 1 || $0.contains { $0.times > 1 } } ?? false }
    public var isStudio: Bool { stems != nil || isArranged }

    /// Seconds of the original the arrangement plays, before speed. Nil when it isn't arranged.
    public var arrangedLength: Double? { sections?.reduce(0) { $0 + $1.span } }

    /// Where a moment of the original plays in the edit, in the edit's seconds: once, more for a loop,
    /// none once cut.
    public func times(of seconds: Double) -> [Double] {
        guard let sections else { return [seconds / speed] }
        var at = 0.0, out: [Double] = []
        for part in sections {
            for _ in 0..<part.times {
                if seconds >= part.start && seconds < part.end { out.append((at + seconds - part.start) / speed) }
                at += part.length
            }
        }
        return out
    }

    /// A stem's level, 1 when the song isn't split.
    public func level(_ stem: String) -> Double { stems?[stem] ?? 1 }

    /// Same song, same settings. The web stores the numbers too, so a hair of float drift still matches.
    public func sameSound(as other: SongEdit) -> Bool {
        (of == other.of || sourceRef.lowercased() == other.sourceRef.lowercased())
            && abs(speed - other.speed) < 0.005 && abs(reverb - other.reverb) < 0.005
            && (pitch == nil) == (other.pitch == nil) && abs((pitch ?? 0) - (other.pitch ?? 0)) < 0.005
            && abs(bass - other.bass) < 0.005
            && Self.stemNames.allSatisfy { abs(level($0) - other.level($0)) < 0.005 }
            && (sections ?? []) == (other.sections ?? [])
    }

    /// For the default name only.
    public var label: String {
        var parts: [String] = []
        if let stems {
            parts.append(Self.stemPresets.first { preset in
                Self.stemNames.allSatisfy { abs((preset.stems?[$0] ?? 1) - (stems[$0] ?? 1)) < 0.005 }
            }?.name ?? "Remix")
        }
        if isArranged { parts.append("Rearranged") }
        var tone: [String] = []
        if let pitch, abs(pitch) >= 0.005 { tone.append(pitch < 0 ? "Pitched Down" : "Pitched Up") }
        if bass >= 0.005 { tone.append("Bass Boosted") }
        if abs(speed - 1) >= 0.005 || reverb >= 0.005 || parts.isEmpty && tone.isEmpty { parts.append(speedLabel) }
        return (parts + tone).joined(separator: " + ")
    }

    private var speedLabel: String {
        let slow = speed < 0.995, fast = speed > 1.005, wet = reverb >= 0.005
        switch (slow, fast, wet) {
        case (true, _, true):  return "Slowed + Reverb"
        case (true, _, false): return "Slowed"
        case (_, true, true):  return "Sped Up + Reverb"
        case (_, true, false): return speed >= 1.3 ? "Nightcore" : "Sped Up"
        case (_, _, true):     return "Reverb"
        default:               return "Edit"
        }
    }

    public struct Preset: Identifiable, Sendable {
        public let name: String
        public let speed: Double
        public let reverb: Double
        public var id: String { name }
    }

    public static let presets: [Preset] = [
        Preset(name: "Original",        speed: 1,    reverb: 0),
        Preset(name: "Slowed + Reverb", speed: 0.85, reverb: 0.35),
        Preset(name: "Slowed",          speed: 0.85, reverb: 0),
        Preset(name: "Sped Up",         speed: 1.2,  reverb: 0),
        Preset(name: "Nightcore",       speed: 1.35, reverb: 0),
    ]

    /// Stem mixes for the Mac studio. Nil levels are the whole song.
    public static let stemPresets: [(name: String, stems: [String: Double]?)] = [
        ("Full Song",    nil),
        ("Instrumental", ["vocals": 0]),
        ("Acapella",     ["drums": 0, "bass": 0, "other": 0]),
        ("Drumless",     ["drums": 0]),
    ]
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        isFinite ? Swift.min(Swift.max(self, range.lowerBound), range.upperBound) : range.lowerBound
    }
}
