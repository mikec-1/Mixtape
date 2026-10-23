// The 10-band EQ node in PlaybackEngine's graph, with presets and persistence.

import AVFoundation
import Combine
import Foundation
import Observation

// MARK: - Preset

public enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat        = "Flat"
    case bassBoost   = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal       = "Vocal"
    case rock        = "Rock"
    case electronic  = "Electronic"
    case rap         = "Rap"
    case acoustic      = "Acoustic"
    case bassReducer   = "Bass Reducer"
    case classical     = "Classical"
    case dance         = "Dance"
    case deep          = "Deep"
    case jazz          = "Jazz"
    case latin         = "Latin"
    case lateNight     = "Late Night"
    case loudness      = "Loudness"
    case lounge        = "Lounge"
    case piano         = "Piano"
    case pop           = "Pop"
    case rnb           = "R&B"
    case smallSpeakers = "Small Speakers"
    case spokenWord    = "Spoken Word"
    case trebleReducer = "Treble Reducer"
    case custom      = "Custom"

    public var id: String { rawValue }

    /// Nil for custom.
    public var gains: [Float]? {
        switch self {
        //                32    64   125   250   500    1k    2k    4k    8k   16k
        case .flat:        return [  0,    0,    0,    0,    0,    0,    0,    0,    0,    0 ]
        case .bassBoost:   return [  6,    5,    4,    2,    0,    0,    0,    0,    0,    0 ]
        case .trebleBoost: return [  0,    0,    0,    0,    0,    1,    2,    4,    5,    6 ]
        case .vocal:       return [ -2,   -1,    0,    2,    4,    4,    3,    1,    0,   -1 ]
        case .rock:        return [  4,    3,    1,   -1,   -1,    0,    1,    2,    3,    4 ]
        case .electronic:  return [  5,    4,    1,    0,   -2,    1,    0,    1,    3,    5 ]
        case .rap:         return [  6,    5,    2,    0,   -1,    1,    3,    3,    2,    1 ]
        case .acoustic:      return [  4,    4,    3,    1,    2,    2,    3,    3,    2,    1 ]
        case .bassReducer:   return [ -6,   -5,   -4,   -2,    0,    0,    0,    0,    0,    0 ]
        case .classical:     return [  4,    3,    2,    1,   -1,   -1,    0,    2,    3,    4 ]
        case .dance:         return [  5,    6,    4,    0,    2,    3,    4,    3,    2,    0 ]
        case .deep:          return [  6,    5,    3,    1,    2,    1,    0,   -2,   -4,   -5 ]
        case .jazz:          return [  4,    3,    1,    2,   -1,   -1,    0,    1,    3,    4 ]
        case .latin:         return [  5,    4,    1,    0,   -1,   -1,   -1,    1,    3,    5 ]
        case .lateNight:     return [ -5,   -4,   -1,    2,    4,    5,    4,    3,    1,    0 ]
        case .loudness:      return [  6,    5,    0,    0,   -2,    0,   -1,   -4,    5,    2 ]
        case .lounge:        return [ -3,   -1,    0,    1,    4,    2,    0,   -1,    2,    1 ]
        case .piano:         return [  2,    1,    0,    2,    3,    1,    2,    4,    3,    2 ]
        case .pop:           return [ -1,   -1,    0,    2,    4,    4,    2,    0,   -1,   -1 ]
        case .rnb:           return [  6,    5,    3,   -1,   -2,    2,    3,    3,    4,    5 ]
        case .smallSpeakers: return [  6,    5,    4,    2,    0,   -1,   -1,    0,    1,    2 ]
        case .spokenWord:    return [ -4,   -3,    0,    2,    4,    5,    5,    4,    1,   -1 ]
        case .trebleReducer: return [  0,    0,    0,    0,    0,   -1,   -2,   -4,   -5,   -6 ]
        case .custom:      return nil
        }
    }
}

// MARK: - Service

@Observable
@MainActor
public final class AudioEqualizer {

    // MARK: - Constants

    /// Standard 10-band graphic EQ centre frequencies (Hz).
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    /// Allowed gain range per band, in dB.
    public static let gainRange: ClosedRange<Float> = -12...12

    /// Active account for EQ settings. Nil is the guest scope.
    nonisolated(unsafe) public static var currentUserID: String? {
        didSet {
            guard oldValue != currentUserID else { return }
            NotificationCenter.default.post(name: .mixEQAccountDidChange, object: nil)
        }
    }

    private enum Keys {
        // Namespaced per account so switching users doesn't leak EQ settings.
        private static var scope: String { AudioEqualizer.currentUserID ?? "guest" }
        static var enabled: String { "mix.eq.\(scope).enabled" }
        static var gains:   String { "mix.eq.\(scope).gains" }
        static var preset:  String { "mix.eq.\(scope).preset" }
    }

    // MARK: - The live node (inserted into PlaybackEngine's graph)

    /// Lazy because creating an AVAudioUnit is slow at launch. Built with the saved curve.
    @ObservationIgnored public lazy var node: AVAudioUnitEQ = {
        let eq = AVAudioUnitEQ(numberOfBands: Self.frequencies.count)
        eq.globalGain = 0

        // Each band is a parametric peaking filter centred on its frequency.
        for (i, freq) in Self.frequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency  = freq
            band.bandwidth  = 1.0           // octaves
            band.bypass     = false
            band.gain       = 0
        }

        eq.bypass = !isEnabled
        for (i, gain) in gains.enumerated() where i < eq.bands.count {
            eq.bands[i].gain = gain
        }
        nodeBuilt = true
        return eq
    }()

    /// Guards writes so they don't force the lazy node into existence.
    @ObservationIgnored private var nodeBuilt = false

    /// Applies `body` to the node only if there is one.
    private func withNode(_ body: (AVAudioUnitEQ) -> Void) {
        guard nodeBuilt else { return }
        body(node)
    }

    // MARK: - Published State (UI binds to these)

    public var isEnabled: Bool {
        didSet {
            withNode { $0.bypass = !isEnabled }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
        }
    }

    public private(set) var gains: [Float]

    /// The currently selected preset. `.custom` once the user moves a slider.
    public private(set) var preset: EqualizerPreset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset) }
    }

    // MARK: - Init

    public init() {
        let bandCount = Self.frequencies.count

        // Restore persisted state.
        let defaults = UserDefaults.standard
        let storedEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        let storedPreset  = (defaults.string(forKey: Keys.preset)).flatMap(EqualizerPreset.init) ?? .flat

        var restoredGains: [Float]
        if let raw = defaults.array(forKey: Keys.gains) as? [Double], raw.count == bandCount {
            restoredGains = raw.map { Float($0) }
        } else if let presetGains = storedPreset.gains {
            restoredGains = presetGains
        } else {
            restoredGains = Array(repeating: 0, count: bandCount)
        }
        // Clamp any out-of-range persisted values defensively.
        restoredGains = restoredGains.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }

        self.isEnabled = storedEnabled
        self.gains     = restoredGains
        self.preset    = storedPreset

        // The node applies this itself when it is built. See `node`.

        // Reload this account's curve whenever the signed-in account changes.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .mixEQAccountDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadForCurrentAccount() }
        }
    }

    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    /// Re-read the persisted EQ for the now-current account and apply it live.
    public func reloadForCurrentAccount() {
        let defaults = UserDefaults.standard
        let bandCount = Self.frequencies.count

        let storedEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        let storedPreset  = (defaults.string(forKey: Keys.preset)).flatMap(EqualizerPreset.init) ?? .flat

        var restoredGains: [Float]
        if let raw = defaults.array(forKey: Keys.gains) as? [Double], raw.count == bandCount {
            restoredGains = raw.map { Float($0) }
        } else if let presetGains = storedPreset.gains {
            restoredGains = presetGains
        } else {
            restoredGains = Array(repeating: 0, count: bandCount)
        }
        restoredGains = restoredGains.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }

        gains = restoredGains
        preset = storedPreset
        isEnabled = storedEnabled
        withNode { eq in
            eq.bypass = !storedEnabled
            for (i, gain) in restoredGains.enumerated() where i < eq.bands.count {
                eq.bands[i].gain = gain
            }
        }
    }

    // MARK: - Mutations

    /// Set the gain (dB) for a single band. Marks the preset as `.custom`.
    public func setGain(_ gain: Float, forBand index: Int) {
        guard gains.indices.contains(index) else { return }
        let clamped = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        gains[index] = clamped
        withNode { if index < $0.bands.count { $0.bands[index].gain = clamped } }
        if preset != .custom { preset = .custom }
        persistGains()
    }

    /// Apply a built-in preset, setting all band gains at once.
    public func apply(_ preset: EqualizerPreset) {
        guard let presetGains = preset.gains else {
            self.preset = .custom
            return
        }
        let clamped = presetGains.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
        gains = clamped
        withNode { eq in
            for (i, gain) in clamped.enumerated() where i < eq.bands.count {
                eq.bands[i].gain = gain
            }
        }
        self.preset = preset
        persistGains()
    }

    /// Reset all bands to 0 dB (Flat).
    public func reset() {
        apply(.flat)
    }

    // MARK: - Persistence

    private func persistGains() {
        UserDefaults.standard.set(gains.map { Double($0) }, forKey: Keys.gains)
    }
}

extension Notification.Name {
    /// Posted when the signed-in account changes so per-account EQ can reload.
    nonisolated static let mixEQAccountDidChange = Notification.Name("mix.eq.accountDidChange")
}
