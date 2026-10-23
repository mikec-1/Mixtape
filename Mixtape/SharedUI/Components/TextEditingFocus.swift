// Tracks whether a text field has focus, so the Mac's ⌘⌫ (a hidden button,
// `MacDeleteCommand`) can be disabled and fall through to the field.
// Fields register by identity: focus moving between fields fires true and
// false in no fixed order, and a lost false would leave ⌘⌫ dead.

import Combine
import SwiftUI
import Observation

extension View {
    /// Marks this view as holding the keyboard. No-op on iOS.
    func mixEditingFocus(_ isFocused: Bool) -> some View {
        modifier(MixEditingFocus(isFocused: isFocused))
    }
}

#if os(macOS)

/// Fields being typed into, app-wide. A singleton because the fields are spread
/// across sheets, popovers and the command palette.
@Observable
@MainActor
final class MacTextEditingMonitor {

    static let shared = MacTextEditingMonitor()

    /// True while any registered field holds the keyboard.
    private(set) var isEditing = false

    @ObservationIgnored private var fields: Set<UUID> = []

    private init() {}

    func set(_ editing: Bool, id: UUID) {
        if editing { fields.insert(id) } else { fields.remove(id) }
        let now = !fields.isEmpty
        if now != isEditing { isEditing = now }
    }
}

private struct MixEditingFocus: ViewModifier {

    let isFocused: Bool

    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear    { MacTextEditingMonitor.shared.set(isFocused, id: token) }
            .onDisappear { MacTextEditingMonitor.shared.set(false, id: token) }
            .onChange(of: isFocused) { _, focused in
                MacTextEditingMonitor.shared.set(focused, id: token)
            }
    }
}
#else
private struct MixEditingFocus: ViewModifier {
    let isFocused: Bool
    func body(content: Content) -> some View { content }
}
#endif
