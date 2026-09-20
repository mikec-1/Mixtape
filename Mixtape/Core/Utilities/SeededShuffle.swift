// SeededShuffle.swift
// Mixtape — Core/Utilities
//
// Deterministic shuffling: the same seed always deals the same hand, on every
// device and every launch.
//
// Plain Foundation and no app types on purpose, so it compiles on its own
// against a standalone `swiftc` check.

import Foundation

/// Small deterministic PRNG so a "roll" is reproducible across view rebuilds.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Which slice of an open-ended pool a smart playlist shows this week.
///
/// A rule like "never played" matches hundreds of songs and shows a hundred.
/// Taking the first hundred means the rest are never seen at all — and for
/// "never played" in particular, nothing about listening can move them up.
/// So the hand is re-dealt each week, from a seed that is the same everywhere:
/// the ISO week and the playlist's own id.
enum WeeklyDeal {

    /// The current ISO week as a number. Rolls over on Monday morning.
    static func week(of date: Date = Date(), calendar: Calendar = Calendar(identifier: .iso8601)) -> UInt64 {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return UInt64(truncatingIfNeeded: (parts.yearForWeekOfYear ?? 0) * 100 + (parts.weekOfYear ?? 0))
    }

    /// A UUID folded to 64 bits. `hashValue` is seeded per process, so two
    /// launches — never mind two devices — would deal different weeks from it.
    ///
    /// All sixteen bytes, not the first eight: the seeded rules are created in
    /// one pass and two ids that differ only in their tail would otherwise deal
    /// the identical hand.
    static func stableSeed(_ id: UUID) -> UInt64 {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                     b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        return bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) {
            ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3
        }
    }

    /// The week's seed for one playlist, put through a finalizer.
    ///
    /// The mixing is not decoration. `SplitMix64` advances its state by the
    /// golden-ratio constant, so two seeds that differ by exactly that constant
    /// produce the *same* stream one step apart — and this week and next are
    /// exactly one apart. Multiplying by it gave consecutive weeks a 55%
    /// overlap in the visible hundred, where independent deals give 25%.
    static func seed(week: UInt64, id: UUID) -> UInt64 {
        var z = stableSeed(id) ^ (week &* 0xD6E8_FEB8_6659_FD93)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// This week's order for `pool`, longest-lived first.
    static func shuffled<T>(_ pool: [T], id: UUID, date: Date = Date()) -> [T] {
        var rng = SplitMix64(seed: seed(week: week(of: date), id: id))
        return pool.shuffled(using: &rng)
    }
}
