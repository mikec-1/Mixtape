// AudioEqualizer.swift
// Mixtape — Core/Services
//
// Owns the AVAudioUnitEQ node that sits in PlaybackEngine's audio graph
// (playerNode -> eqNode -> mainMixerNode). Exposes a 10-band graphic EQ
// with built-in presets and UserDefaults persistence so a SwiftUI view can
// bind sliders to band gains and hear changes live.
//
// The node is created up-front and handed to PlaybackEngine for insertion
// into the AVAudioEngine graph. Gain/enabled changes are applied to the live
// node immediately.

import AVFoundation
import Combine
import Foundation

// MARK: - Preset

public enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat        = "Flat"
    case bassBoost   = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal       = "Vocal"
    case rock        = "Rock"
    case electronic  = "Electronic"
    case rap         = "Rap"
    case custom      = "Custom"

    public var id: String { rawValue }

    /// Per-band gains in dB, aligned to `AudioEqualizer.frequencies`.
    /// `custom` returns nil — it represents a user-edited curve, not a fixed one.
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
        case .custom:      return nil
        }
    }
}

// MARK: - Service

@MainActor
public final class AudioEqualizer: ObservableObject {

    // MARK: - Constants

    /// Standard 10-band graphic EQ centre frequencies (Hz).
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    /// Allowed gain range per band, in dB.
    public static let gainRange: ClosedRange<Float> = -12...12

    /// The account whose EQ settings are active. Set by the auth layer on
    /// sign-in / account switch / sign-out so each account keeps its own EQ
    /// instead of sharing one global curve. `nil` → a shared "guest" scope.
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

    /// The AVAudioUnitEQ node. Created once, on first use; PlaybackEngine
    /// attaches & connects it.
    ///
    /// Lazy because building it was 946 ms of a cold iOS launch — instantiating
    /// an AVAudioUnit pulls in the audio component registry, and none of that is
    /// needed until either something plays or the user opens the EQ. It is built
    /// with the persisted curve already applied, so nothing has to remember to
    /// push state into it afterwards.
    public lazy var node: AVAudioUnitEQ = {
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

    /// Whether `node` has actually been created.
    ///
    /// Every write to the node is guarded on this. Touching `node` to push a
    /// value into it would build the very thing the laziness exists to defer —
    /// and it would be pointless, because a node built later reads the current
    /// `isEnabled` / `gains` on the way up.
    private var nodeBuilt = false

    /// Applies `body` to the node only if there is one.
    private func withNode(_ body: (AVAudioUnitEQ) -> Void) {
        guard nodeBuilt else { return }
        body(node)
    }

    // MARK: - Published State (UI binds to these)

    @Published public var isEnabled: Bool {
        didSet {
            withNode { $0.bypass = !isEnabled }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
        }
    }

    /// Per-band gains in dB, aligned to `frequencies`. Editing a value live-updates the node.
    @Published public private(set) var gains: [Float]

    /// The currently selected preset. `.custom` once the user moves a slider.
    @Published public private(set) var preset: EqualizerPreset {
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

    private var accountObserver: NSObjectProtocol?

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
            // `.custom` has no fixed curve — just record the selection.
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
    static let mixEQAccountDidChange = Notification.Name("mix.eq.accountDidChange")
}
