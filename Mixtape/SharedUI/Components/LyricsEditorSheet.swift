// LyricsEditorSheet.swift
// Mixtape — SharedUI/Components
//
// Where someone types, pastes or opens the lyrics for a song the lookup
// couldn't find — or found wrong.
//
// One sheet for both platforms, because the task is identical on both: a box of
// text and a file picker. `MixSheet` already handles the parts that genuinely
// differ (footer placement, detents, the phone's close control), so nothing
// here is `#if`-ed except the pasteboard, which has two different names.
//
// The live status line under the box is the point of the design. LRC is a
// format with an invisible failure mode — one malformed timestamp and the file
// silently degrades to a plain block of text — so the sheet parses what's in
// the box as it's typed and says which of the two it is, and how many lines it
// found. That answer is produced by the same `LyricsService.parse` the player
// will use, so it can't disagree with what happens after Save.

import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorSheet: View {

    let track: Track

    @StateObject private var lyricsService = LyricsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var loaded = false
    @State private var showFilePicker = false
    @State private var fileError: String?

    /// `.lrc` isn't a registered system type, so it's declared by extension.
    /// The plain-text types stay alongside it: plenty of lyrics arrive as a
    /// .txt, and a picker that greys those out would be lying about what the
    /// box below accepts.
    private var allowedTypes: [UTType] {
        [UTType(filenameExtension: "lrc"), .plainText, .text, .utf8PlainText].compactMap { $0 }
    }

    /// What `text` parses to, recomputed when it changes rather than when the
    /// body runs. The status line reads it twice per pass and the body runs on
    /// every keystroke, so as a computed property this parsed the whole lyric
    /// two or three times per character typed.
    @State private var parsed: TrackLyrics = .empty

    /// Whether this song already had lyrics stored when the sheet opened.
    /// Cached for the same reason: it's a directory listing, and the title, the
    /// Save button and the Remove button each asked for it per body pass.
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
        // The editor opens onto whatever is already stored. Deliberately only
        // the user's own text: pre-filling from a lookup would turn "add the
        // lyrics this song is missing" into "confirm the ones we guessed", and
        // saving that would pin a guess in place permanently.
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

            // Only offered once there is something stored to remove — before
            // that it would be a button that undoes nothing.
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

    /// What the text view insets its own text by, on top of `editorPadding`.
    ///
    /// The placeholder is a plain `Text` sitting behind the editor, so it only
    /// lines up with the caret if it's inset by *both* numbers. Hand-picked
    /// values (the 12/10 this started with) can't line up — they're guessing at
    /// a platform constant. These are that constant: AppKit's line-fragment
    /// padding, and on UIKit the same plus `UITextView`'s vertical
    /// `textContainerInset`.
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
        // Takes the sheet's remaining height. Bounded, because `MixSheet`
        // bounds itself on both platforms — an unbounded greedy editor here is
        // what grew the playlist sheet to the size of a screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Monospaced once the text carries timestamps, so `[00:12.40]` columns
    /// line up down the left edge the way an .lrc is meant to read.
    private var editorFont: Font {
        .system(size: 13, design: text.contains("[") ? .monospaced : .default)
    }

    /// The placeholder shows only when `text` is empty, which is exactly when
    /// `editorFont` is the default design — but deriving it keeps the two from
    /// drifting apart if either changes.
    private var placeholderFont: Font { .system(size: 13) }

    /// What Save is about to produce, in the words the player uses.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 11, weight: .semibold))
            Text(statusText)
                .font(.system(size: 12))
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

        // The picker hands back a security-scoped URL on both platforms; a read
        // without the claim silently fails on a sandboxed build.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Lyrics files in the wild are frequently not UTF-8 — a lot of the .lrc
        // corpus is Windows-1252 or Shift-JIS. Falling back beats refusing the
        // file, and a mangled accent the user can fix in the box beats an
        // error they can't act on.
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
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
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
