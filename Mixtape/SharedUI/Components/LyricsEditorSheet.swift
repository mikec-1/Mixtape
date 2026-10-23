// Add or fix lyrics for a song. One sheet for both platforms; `MixSheet` handles
// the differences. The status line parses as you type with `LyricsService.parse`
// (same as the player) and says synced vs plain and the line count.

import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorSheet: View {

    let track: Track

    private var lyricsService: LyricsService { .shared }
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var loaded = false
    @State private var showFilePicker = false
    @State private var fileError: String?

    /// `.lrc` isn't a system type, so declare it. Plain text is accepted too.
    private var allowedTypes: [UTType] {
        [UTType(filenameExtension: "lrc"), .plainText, .text, .utf8PlainText].compactMap { $0 }
    }

    /// Parsed on change, not in body, which runs per keystroke.
    @State private var parsed: TrackLyrics = .empty

    /// Cached since it's a directory listing read several times per pass.
    @State private var hadStored = false

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        MixSheet(title: hadStored ? "Edit Lyrics" : "Add Lyrics",
                 subtitle: subtitle,
                 size: .large,
                 scroll: false,
                 primary: MixSheetAction("Save", isEnabled: hasText || hadStored) { save() }) {
            content
        }
        // Pre-fill only the user's stored text, never a lookup result.
        .task {
            guard !loaded else { return }
            text = lyricsService.userLyricsText(for: track) ?? ""
            hadStored = !text.isEmpty
            parsed = LyricsService.parse(text)
            loaded = true
        }
        .onChange(of: text) { _, new in parsed = LyricsService.parse(new) }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: allowedTypes) { result in
            open(result)
        }
    }

    private var subtitle: String {
        let artists = ImportService.displayArtists(title: track.title, artistName: track.artistName)
        return "\(track.title) — \(artists.joined(separator: ", "))"
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceRow
            editor
            statusLine
        }
        .padding(.horizontal, MixSheetMetrics.margin)
        .padding(.vertical, MixSheetMetrics.contentVertical)
    }

    /// The two ways to fill the box that aren't typing.
    private var sourceRow: some View {
        HStack(spacing: 8) {
            smallButton("Open File…", icon: "folder") { showFilePicker = true }
            smallButton("Paste", icon: "doc.on.clipboard") { paste() }

            Spacer(minLength: 0)

            // Only once something is stored.
            if hadStored {
                smallButton("Remove", icon: "trash", isDestructive: true) {
                    lyricsService.removeUserLyrics(for: track)
                    dismiss()
                }
            }
        }
    }

    /// Padding applied to the `TextEditor` itself.
    private static let editorPadding: CGFloat = 6

    /// The text view's own inset (AppKit line-fragment padding; UIKit adds
    /// `textContainerInset`). The placeholder needs both to line up with the caret.
    #if os(macOS)
    private static let textInset = CGSize(width: 5, height: 0)
    #else
    private static let textInset = CGSize(width: 5, height: 8)
    #endif

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Paste the lyrics here, or open an .lrc file.\n\nTimestamps like [00:12.40] make them scroll with the song.")
                    .font(placeholderFont)
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.leading, Self.editorPadding + Self.textInset.width)
                    .padding(.trailing, Self.editorPadding)
                    .padding(.top, Self.editorPadding + Self.textInset.height)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(editorFont)
                .foregroundStyle(Color.mixTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(Self.editorPadding)
        }
        // Bounded, or the editor grows the sheet to screen size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Monospaced once there are timestamps.
    private var editorFont: Font {
        .system(size: MixFontScale.size(13), design: text.contains("[") ? .monospaced : .default)
    }

    /// Kept separate from `editorFont` in case either changes.
    private var placeholderFont: Font { .system(size: MixFontScale.size(13)) }

    /// What Save is about to produce, in the words the player uses.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 11, weight: .semibold))
            Text(statusText)
                .font(.system(size: MixFontScale.size(12)))
            Spacer(minLength: 0)
        }
        .foregroundStyle(fileError == nil ? Color.mixTextSecondary : Color.mixDestructive)
    }

    private var statusIcon: String {
        if fileError != nil { return "exclamationmark.triangle" }
        if parsed.hasSynced { return "waveform" }
        return hasText ? "text.alignleft" : "text.quote"
    }

    private var statusText: String {
        if let fileError { return fileError }
        if parsed.hasSynced {
            let n = parsed.synced.count
            return "Synced — \(n) timed line\(n == 1 ? "" : "s"), highlighted as the song plays."
        }
        if hasText {
            return "Plain lyrics — no timestamps found, so they won't scroll with the song."
        }
        return hadStored ? "Clearing the box and saving removes your lyrics." : "Nothing to save yet."
    }

    // MARK: - Actions

    private func save() {
        lyricsService.saveUserLyrics(text, for: track)
        dismiss()
    }

    private func open(_ result: Result<URL, Error>) {
        fileError = nil
        guard case .success(let url) = result else { return }

        // Security-scoped on both platforms; reads fail without it when sandboxed.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Many .lrc files aren't UTF-8, so fall back to other encodings.
        guard let data = try? Data(contentsOf: url) else {
            fileError = "Couldn't read that file."
            return
        }
        guard let contents = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            fileError = "Couldn't read that file as text."
            return
        }
        text = contents
    }

    private func paste() {
        fileError = nil
        #if os(macOS)
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        #else
        guard let pasted = UIPasteboard.general.string else { return }
        #endif
        text = pasted
    }

    // MARK: - Small button

    private func smallButton(_ title: String,
                             icon: String,
                             isDestructive: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: MixFontScale.size(11), weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDestructive ? Color.mixDestructive : Color.mixTextPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.mixSurface2, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}
