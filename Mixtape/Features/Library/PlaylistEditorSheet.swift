// PlaylistEditorSheet.swift
// Mixtape — Features/Library
//
// Shared iOS + macOS sheet for creating or editing a playlist.
// Lets the user pick a cover photo, set a name, and write an optional description —
// matching the Spotify "Edit details" pattern.

import SwiftUI

// MARK: - PlaylistEditorSheet

public struct PlaylistEditorSheet: View {

    let editingPlaylist: Playlist?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var name        = ""
    @State private var description = ""
    @State private var artworkData: Data? = nil
    /// What the picker was showing when the sheet opened.
    ///
    /// A playlist with no cover of its own still *shows* one — the mosaic it
    /// borrows from its songs — and the picker has to show that too, or opening
    /// Edit Details on a playlist that plainly has a cover would present an
    /// empty square. But it must not be saved back: writing the borrowed image
    /// in would turn a cover that follows the songs into a fixed one, and would
    /// mark it as chosen by a user who only came here to fix a typo. So the
    /// cover is written only when this and `artworkData` differ.
    @State private var originalArtwork: Data? = nil

    public init(editingPlaylist: Playlist? = nil) {
        self.editingPlaylist = editingPlaylist
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var titleText: String {
        editingPlaylist != nil ? "Edit Playlist" : "New Playlist"
    }

    // MARK: - Body

    public var body: some View {
        // One layout now. The two platform bodies below had drifted into
        // different sheets entirely — different titles, different close
        // affordances, a pill Save on one and a bordered Save on the other,
        // and a description box that had to be height-pinned on iOS because it
        // was the only greedy view on a full-height detent. The shared chrome
        // bounds the sheet, so the field can just be a field.
        MixSheet(title: titleText,
                 subtitle: editingPlaylist == nil
                     ? "Give it a name — you can change it later."
                     : nil,
                 size: .medium,
                 primary: MixSheetAction("Save", isEnabled: canSave, action: save)) {
            fields
        }
        .task(id: editingPlaylist?.id) { setupInitialState() }
    }

    // MARK: - Fields

    private var fields: some View {
        HStack(alignment: .top, spacing: 16) {
            artworkPickerView(size: 120)
            VStack(spacing: 10) {
                nameFieldView
                descriptionFieldView
            }
            .frame(height: 120)
        }
    }

    private func setupInitialState() {
        if let playlist = editingPlaylist {
            name = playlist.name
            description = playlist.description ?? ""
            artworkData     = playlist.displayArtwork
            originalArtwork = artworkData
        } else {
            name = defaultName()
        }
    }

    // MARK: - Artwork picker

    private func artworkPickerView(size: CGFloat) -> some View {
        ArtworkPickerView<AnyView>.standard(data: $artworkData, size: size)
    }

    // MARK: - Name field

    private var nameFieldView: some View {
        TextField("Playlist name", text: $name)
            .mixSheetField()
    }

    // MARK: - Description field  (ZStack placeholder trick — TextEditor has no built-in placeholder)

    /// Padding applied to the `TextEditor` itself.
    private static let editorPadding: CGFloat = 6

    /// What the text view insets its own text by, on top of `editorPadding`.
    ///
    /// The placeholder only lines up with the caret if it's inset by *both*
    /// numbers. The hand-picked 12/10 this used to carry couldn't line up —
    /// they were guessing at a platform constant instead of naming it. These
    /// are that constant: AppKit's line-fragment padding, and on UIKit the same
    /// plus `UITextView`'s vertical `textContainerInset`.
    #if os(macOS)
    private static let textInset = CGSize(width: 5, height: 0)
    #else
    private static let textInset = CGSize(width: 5, height: 8)
    #endif

    private var descriptionFieldView: some View {
        ZStack(alignment: .topLeading) {
            if description.isEmpty {
                Text("Add an optional description")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.leading, Self.editorPadding + Self.textInset.width)
                    .padding(.trailing, Self.editorPadding)
                    .padding(.top, Self.editorPadding + Self.textInset.height)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $description)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.mixTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(Self.editorPadding)
        }
        // Takes whatever the column has left under the name field. The column
        // is pinned to the cover's height in `fields`, so this is bounded on
        // both platforms now — it used to be the only greedy view in an
        // unbounded iOS sheet, which is how it grew to the size of a screen.
        .frame(maxHeight: .infinity)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimDesc = description.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        
        if let playlist = editingPlaylist {
            // Details and cover written separately, and the cover only if it
            // actually changed. They used to go through one call that always
            // wrote both, which meant every rename also re-wrote the cover —
            // and re-wrote a *borrowed* one as if the user had picked it.
            deps.libraryService.setPlaylistDetails(
                id:          playlist.id,
                name:        trimName,
                description: trimDesc.isEmpty ? nil : trimDesc
            )
            if artworkData != originalArtwork {
                deps.libraryService.setPlaylistArtwork(id: playlist.id, data: artworkData)
            }
        } else {
            _ = deps.libraryService.createPlaylist(
                name:        trimName,
                description: trimDesc.isEmpty ? nil : trimDesc,
                artworkData: artworkData
            )
        }
        
        Task { try? await deps.syncService.sync() }
        dismiss()
    }

    /// "My Playlist #N" where N = number of existing user playlists + 1.
    private func defaultName() -> String {
        let count = deps.libraryService.playlists.filter { !$0.isSystem && !$0.isDeleted }.count
        return "My Playlist #\(count + 1)"
    }
}

// MARK: - Preview

#Preview {
    PlaylistEditorSheet()
        .environmentObject(AppDependencies())
}
