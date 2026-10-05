// The window's search field: a Spotify-style pill instead of `.searchable`, centred by MacTopBar.
// ⌘F comes from an invisible button in MacRootView via `searchFocusToken`.

#if os(macOS)
import SwiftUI

struct MacSearchField: View {

    @Binding var text: String
    let prompt: String

    /// Incremented externally (⌘F) to request focus.
    var focusToken: Int = 0

    /// ↓ while typing hands keyboard control to the results list.
    var onMoveDown: (() -> Void)? = nil

    /// ↑/↓ offered to the suggestions panel first. True means it moved; false falls through.
    var onArrowDown: (() -> Bool)? = nil
    var onArrowUp:   (() -> Bool)? = nil

    /// Return. Activates the highlighted suggestion, or commits the query.
    var onSubmit: (() -> Void)? = nil

    /// Escape closes the suggestions panel; `.ignored` lets MacRootView handle it.
    var onCancel: (() -> Bool)? = nil

    /// Focus gained/lost, so the host can hide a panel anchored to this field.
    var onFocusChange: ((Bool) -> Void)? = nil

    /// False refuses focus, for moments when AppKit hands the field focus on its own.
    var acceptsFocus: (() -> Bool)? = nil

    /// Set by the host so the pill fills the bar.
    var height: CGFloat = 34

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    /// Live only while focused; see `SearchBlurWatcher`.
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
                // ↓ walks the suggestions while open, then moves focus to the results.
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
                // ⌘⌫ clears the line instead of deleting the list selection.
                .mixEditingFocus(isFocused)

            // ⌘F hint while idle, clear button once there's a query.
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
            // Fixed slot so the field doesn't reflow when the accessory swaps.
            .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        // Flexible: at 150% zoom a fixed width would collide with the controls either side.
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
            if focused, acceptsFocus?() == false { isFocused = false; return }
            onFocusChange?(focused)
            // AppKit won't unfocus on an outside click, so the watcher runs while this field is focused.
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
