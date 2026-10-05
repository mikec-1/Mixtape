// Inline search field for everywhere but the Mac toolbar (MacSearchField).
// Not `.searchable`, which puts the field in the nav bar/toolbar.

import SwiftUI

struct MixSearchField: View {

    @Binding var text: String
    var placeholder: String = "Search"
    /// Spinner replaces the clear button.
    var isBusy: Bool = false
    /// Taller, for views built around the field.
    var isProminent: Bool = false
    /// Focus on appear. For windows meant for typing, not list filters.
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool

    #if os(macOS)
    /// macOS doesn't drop focus on click-away by itself. Only live while focused.
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
            // A presenting sheet drops focus requests, so wait.
            try? await Task.sleep(for: .milliseconds(120))
            isFocused = true
        }
    }
}
