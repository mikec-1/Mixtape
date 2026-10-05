// Row marker for where a song's audio lives. The AppKit table draws the same
// `TrackAvailability.badge*` values.

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
