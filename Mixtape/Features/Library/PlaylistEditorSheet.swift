// Shared sheet for creating or editing a playlist: cover, name and description.

import SwiftUI

// MARK: - PlaylistEditorSheet

public struct PlaylistEditorSheet: View {

    let editingPlaylist: Playlist?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var name        = ""
    @State private var description = ""
    @State private var artworkData: Data? = nil
    /// The cover shown when the sheet opened, which may be borrowed from the
    /// songs. Only written back if `artworkData` differs, so a rename doesn't pin it.
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
        // One shared layout. MixSheet bounds the sheet, so the description field can just be a field.
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

    // MARK: - Description field  (ZStack placeholder, TextEditor has none)

    /// Padding applied to the `TextEditor` itself.
    private static let editorPadding: CGFloat = 6

    /// The text view's own inset on top of `editorPadding`, so the placeholder lines
    /// up with the caret: AppKit's line-fragment padding, plus `textContainerInset` on UIKit.
    #if os(macOS)
    private static let textInset = CGSize(width: 5, height: 0)
    #else
    private static let textInset = CGSize(width: 5, height: 8)
    #endif

    private var descriptionFieldView: some View {
        ZStack(alignment: .topLeading) {
            if description.isEmpty {
                Text("Add an optional description")
                    .font(.system(size: MixFontScale.size(13.5)))
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.leading, Self.editorPadding + Self.textInset.width)
                    .padding(.trailing, Self.editorPadding)
                    .padding(.top, Self.editorPadding + Self.textInset.height)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $description)
                .font(.system(size: MixFontScale.size(13.5)))
                .foregroundStyle(Color.mixTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(Self.editorPadding)
        }
        // Fills what's left under the name field. Bounded by the cover's height in `fields`.
        .frame(maxHeight: .infinity)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimDesc = description.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        
        if let playlist = editingPlaylist {
            // Details and cover are written separately, and the cover only if it changed.
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
