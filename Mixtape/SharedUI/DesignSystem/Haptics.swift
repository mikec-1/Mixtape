// Cross-platform haptics. No-op on macOS. Respects "haptics.enabled" (default on).

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public enum Haptics {

    public enum Style {
        case light, medium, heavy, soft, rigid
        case selection
        case success, warning, error
    }

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "haptics.enabled") as? Bool ?? true
    }

    public static func play(_ style: Style) {
        guard isEnabled else { return }
        #if canImport(UIKit) && os(iOS)
        switch style {
        case .light:  UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:  UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .soft:   UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid:  UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}
