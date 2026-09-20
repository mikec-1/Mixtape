// MacSearchField.swift
// Mixtape — Mac/App
//
// The window's single search field, styled as a Spotify-style pill rather than
// the system `.searchable` chrome. `.searchable` renders as a wide, tall bar in
// the toolbar that dominates the Discover header; this is a capsule that reads
// as one control among the top bar's others. Hosted by MacTopBar, which centres
// it on the window.
//
// Focus: `.searchable` gave us ⌘F for free. Since the field is ours now,
// MacRootView hosts an invisible ⌘F button that calls `appState.focusSearch()`,
// and we pick that up through `searchFocusToken`.

#if os(macOS)
import SwiftUI

struct MacSearchField: View {

    @Binding var text: String
    let prompt: String

    /// Incremented externally (⌘F) to request focus.
    var focusToken: Int = 0

    /// ↓ pressed while typing — the host hands keyboard control to the results
    /// list. Nil leaves the arrow key to the text field.
    var onMoveDown: (() -> Void)? = nil

    /// ↑/↓ offered to the suggestions panel first. Returning true means the panel
    /// moved its highlight and the key is spent; false falls through — ↓ to
    /// `onMoveDown`, ↑ to the text field's own caret movement.
    var onArrowDown: (() -> Bool)? = nil
    var onArrowUp:   (() -> Bool)? = nil

    /// Return. Activates the highlighted suggestion, or commits the query.
    var onSubmit: (() -> Void)? = nil

    /// Escape. Closes the suggestions panel; MacRootView's own `.onExitCommand`
    /// still handles Escape for panels when this returns `.ignored`.
    var onCancel: (() -> Bool)? = nil

    /// Focus gained/lost, so the host can hide a panel anchored to this field.
    var onFocusChange: ((Bool) -> Void)? = nil

    /// Pill height. The host sets it from the bar it centres this in, so the
    /// field fills the bar the way Spotify's does instead of floating as a thin
    /// capsule in the middle of it. Default is the old fixed value.
    var height: CGFloat = 34

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    /// Live only while the field is focused — see `SearchBlurWatcher`.
    @StateObject private var blurWatcher = SearchBlurWatcher()

    private var isActive: Bool { isFocused || !text.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Color.mixTextPrimary : Color.mixTextTertiary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextPrimary)
                .focused($isFocused)
                // The suggestions panel gets first refusal on ↓ so the arrow
                // walks the dropdown while it's open, and only jumps focus into
                // the results list once it isn't.
                .onKeyPress(.downArrow) {
                    if onArrowDown?() == true { return .handled }
                    guard let onMoveDown else { return .ignored }
                    onMoveDown()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onArrowUp?() == true ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    onCancel?() == true ? .handled : .ignored
                }
                .onSubmit { onSubmit?() }
                // ⌘⌫ clears the line here, rather than offering to delete
                // whatever is selected in the list behind the search.
                .mixEditingFocus(isFocused)

            // One trailing slot, two states: a ⌘F hint while the field is idle
            // (the shortcut is otherwise invisible now that `.searchable` is
            // gone), swapping to the clear button as soon as there's a query.
            ZStack(alignment: .trailing) {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .opacity(isActive ? 0 : 1)

                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()
                .opacity(text.isEmpty ? 0 : 1)
                .allowsHitTesting(!text.isEmpty)
                .help("Clear search")
            }
            // Fixed slot so the text field never reflows as the trailing
            // accessory swaps between the hint and the clear button.
            .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        // Flexible rather than a hard 360: MacTopBar centres this on the window
        // and caps it, but at 150 % zoom the logical window is only ~640pt wide
        // and a fixed width would have collided with the controls either side.
        .frame(height: height)
        .frame(minWidth: 180, maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(Color.mixSurface2.opacity(isHovered || isActive ? 1 : 0.6))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isFocused ? Color.mixPrimary.opacity(0.75) : Color.mixSeparator,
                              lineWidth: 1)
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { isFocused = true }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
        .onChange(of: focusToken) { _, _ in isFocused = true }
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
            // Clicking anywhere else has to put the caret down. AppKit won't do
            // it on its own (see SearchBlurWatcher), so the watcher runs for
            // exactly as long as this field holds the keyboard.
            if focused { blurWatcher.start { isFocused = false } }
            else       { blurWatcher.stop() }
        }
        .onDisappear { blurWatcher.stop() }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
        .mixAnimation(.easeOut(duration: 0.12), value: isFocused)
        .mixAnimation(.easeOut(duration: 0.12), value: text.isEmpty)
    }
}

#endif
