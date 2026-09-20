// MixSearchField.swift
// Mixtape — SharedUI/Components
//
// The app's inline search field, for anywhere that isn't the Mac window's own
// toolbar (that one is MacSearchField).
//
// Deliberately not `.searchable`: it puts the field in the navigation bar on iOS
// and the toolbar on macOS, and every place this is used owns its own content
// area rather than the chrome around it.

import SwiftUI

struct MixSearchField: View {

    @Binding var text: String
    var placeholder: String = "Search"
    /// Shows a spinner in place of the clear button. Keeps the "working on it"
    /// signal next to the thing being typed into, instead of replacing the
    /// results below with a full-view spinner that throws the layout around.
    var isBusy: Bool = false
    /// Taller and slightly larger type, for a view whose whole purpose is this
    /// field rather than one that merely offers it.
    var isProminent: Bool = false
    /// Puts the caret here as the view appears — right for a window that exists
    /// to be typed into, wrong for a field that merely filters a list.
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool

    #if os(macOS)
    /// Clicking away from a focused field has to put the caret down; on macOS
    /// nothing does that on its own. Live only while this field is focused.
    @StateObject private var blurWatcher = SearchBlurWatcher()
    #endif

    var body: some View {
        HStack(spacing: isProminent ? 9 : 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isProminent ? 14 : 12, weight: .medium))
                .foregroundStyle(Color.mixTextTertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(isProminent ? .mixBody : .mixSubtext)
                .foregroundStyle(Color.mixTextPrimary)
                .focused($isFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { isFocused = false }
                // ⌘⌫ belongs to the field while the caret is in it.
                .mixEditingFocus(isFocused)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.mixTextTertiary)
            } else if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: isProminent ? 14 : 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(.horizontal, isProminent ? 11 : 9)
        .padding(.vertical, isProminent ? 9 : 7)
        .background(
            RoundedRectangle(cornerRadius: isProminent ? 10 : 8, style: .continuous)
                .fill(Color.mixSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isProminent ? 10 : 8, style: .continuous)
                .strokeBorder(isFocused ? Color.mixPrimary.opacity(0.6) : Color.mixSeparator,
                              lineWidth: isFocused ? 1 : 0.5)
        )
        #if os(macOS)
        .onChange(of: isFocused) { _, focused in
            if focused { blurWatcher.start { isFocused = false } }
            else       { blurWatcher.stop() }
        }
        .onDisappear { blurWatcher.stop() }
        #endif
        .mixAnimation(.easeOut(duration: 0.15), value: isFocused)
        .mixAnimation(.easeOut(duration: 0.15), value: isBusy)
        .task {
            guard autoFocus else { return }
            // A sheet that isn't finished presenting drops the focus request,
            // so this waits for the window to settle before asking.
            try? await Task.sleep(for: .milliseconds(120))
            isFocused = true
        }
    }
}
