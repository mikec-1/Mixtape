// Deterministic shuffling, same result on every device and launch. Foundation
// only so it compiles standalone with `swiftc`.

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
/// Re-dealt weekly from the ISO week and the rule, so every song gets seen.
/// Keyed on the rule, not the playlist id: built-ins get a fresh id per device.
enum WeeklyDeal {

    /// The current ISO week as a number. Rolls over on Monday morning.
    static func week(of date: Date = Date(), calendar: Calendar = Calendar(identifier: .iso8601)) -> UInt64 {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return UInt64(truncatingIfNeeded: (parts.yearForWeekOfYear ?? 0) * 100 + (parts.weekOfYear ?? 0))
    }

    /// FNV-1a over the key's UTF-8. `hashValue` is per-process.
    static func stableSeed(_ key: String) -> UInt64 {
        key.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) {
            ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3
        }
    }

    /// The week's seed for a key, mixed through a finalizer. Without it,
    /// consecutive weeks are one SplitMix64 step apart and overlap heavily.
    static func seed(week: UInt64, key: String) -> UInt64 {
        var z = stableSeed(key) ^ (week &* 0xD6E8_FEB8_6659_FD93)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// This week's order for `pool`, longest-lived first.
    static func shuffled<T>(_ pool: [T], key: String, date: Date = Date()) -> [T] {
        var rng = SplitMix64(seed: seed(week: week(of: date), key: key))
        return pool.shuffled(using: &rng)
    }
}
