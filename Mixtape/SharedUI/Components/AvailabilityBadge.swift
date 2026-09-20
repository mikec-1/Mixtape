// AvailabilityBadge.swift
// Mixtape — SharedUI/Components
//
// The row marker for "where does this song's audio live". One view for both
// platforms' SwiftUI rows; the Mac's AppKit table draws the same decision from
// the same `TrackAvailability.badge*` properties (see NativeTrackTable).

import SwiftUI

struct AvailabilityBadge: View {

    let availability: TrackAvailability
    var size: CGFloat = 10

    private var tint: Color {
        switch availability.badgeTint {
        case .positive: return .green
        case .active:   return .mixPrimary
        case .negative: return .red
        }
    }

    var body: some View {
        if let symbol = availability.badgeSymbol {
            let image = Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityLabel(availability.badgeDescription ?? "")

            if availability.badgePulses {
                image.mixPulse()
            } else {
                image
            }
        }
    }
}
