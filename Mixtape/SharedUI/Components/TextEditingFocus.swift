// TextEditingFocus.swift
// Mixtape — SharedUI/Components
//
// "A text field has the keyboard right now."
//
// The Mac's ⌘⌫ is a hidden `Button` in the window (`MacDeleteCommand`), and a
// key equivalent on a button beats whatever is being typed into: with the caret
// in the playlist's search field, ⌘⌫ — which means "clear this line" in every
// other Mac text field — was offering to delete the song that happened to be
// selected behind it.
//
// A shortcut can't ask who the first responder is, but it can be disabled, and
// a disabled key equivalent isn't swallowed: the event carries on down the
// responder chain and the field does the ordinary thing with it. So fields say
// when they're being typed into, and the app-wide destructive shortcut stands
// down for as long as that's true.
//
// Fields register by identity rather than flipping a shared flag, because focus
// moving from one field to another fires the new field's `true` and the old
// field's `false` in an order nobody controls — and a lost `false` would leave
// ⌘⌫ dead for the rest of the session.

import Combine
import SwiftUI

extension View {
    /// Marks this view as a text field holding (or not holding) the keyboard.
    /// A no-op on iOS, which has no key equivalents to defend against.
    func mixEditingFocus(_ isFocused: Bool) -> some View {
        modifier(MixEditingFocus(isFocused: isFocused))
    }
}

#if os(macOS)

/// The set of fields currently being typed into, app-wide.
///
/// A singleton rather than something handed down the environment: the fields
/// that need it are scattered across sheets, popovers and the command palette's
/// own overlay, and a shared view that crashes wherever an ancestor forgot to
/// inject something is a worse trade than one global with two members.
@MainActor
final class MacTextEditingMonitor: ObservableObject {

    static let shared = MacTextEditingMonitor()

    /// True while any registered field holds the keyboard.
    @Published private(set) var isEditing = false

    private var fields: Set<UUID> = []

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
