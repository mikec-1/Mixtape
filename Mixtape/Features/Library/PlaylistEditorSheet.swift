// PlaylistEditorSheet.swift
// Mixtape — Features/Library
//
// Shared iOS + macOS sheet for creating or editing a playlist.
// Lets the user pick a cover photo, set a name, and write an optional description —
// matching the Spotify "Edit details" pattern.

#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PlaylistEditorSheet

public struct PlaylistEditorSheet: View {

    let editingPlaylist: Playlist?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var name        = ""
    @State private var description = ""
    @State private var artworkData: Data? = nil

    #if os(iOS)
    @State private var photoItem: PhotosPickerItem? = nil
    #elseif os(macOS)
    @State private var showFilePicker = false
    #endif

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
        #if os(iOS)
        iosBody
            .task(id: editingPlaylist?.id) { setupInitialState() }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        artworkData = data
                    }
                }
            }
        #elseif os(macOS)
        macBody
            .task(id: editingPlaylist?.id) { setupInitialState() }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result,
                      url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                artworkData = try? Data(contentsOf: url)
            }
        #endif
    }
    
    private func setupInitialState() {
        if let playlist = editingPlaylist {
            name = playlist.name
            description = playlist.description ?? ""
            artworkData = playlist.artworkData
        } else {
            name = defaultName()
        }
    }

    // MARK: - iOS layout

    #if os(iOS)
    private var iosBody: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                // ── Header ─────────────────────────────────────────────────────
                HStack {
                    Text(titleText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 28, height: 28)
                            .background(Color.mixSurface2, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 24)

                // ── Fields ─────────────────────────────────────────────────────
                HStack(alignment: .top, spacing: 14) {
                    artworkPickerView(size: 130)
                    VStack(spacing: 10) {
                        nameFieldView
                        descriptionFieldView
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // ── Save button ────────────────────────────────────────────────
                Button { save() } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 50))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
        }
    }
    #endif

    // MARK: - macOS layout

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {

            // ── Header ─────────────────────────────────────────────────────────
            HStack {
                Text(titleText)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.mixSurface2, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(20)

            Divider()

            // ── Fields ─────────────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 16) {
                artworkPickerView(size: 120)
                VStack(spacing: 10) {
                    nameFieldView
                    descriptionFieldView
                }
            }
            .padding(20)

            Divider()

            // ── Footer ─────────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Color.mixTextSecondary)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mixPrimary)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(Color.mixBackground)
    }
    #endif

    // MARK: - Artwork picker

    @ViewBuilder
    private func artworkPickerView(size: CGFloat) -> some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItem, matching: .images) {
            artworkSquare(size: size)
        }
        .buttonStyle(.plain)
        #elseif os(macOS)
        Button { showFilePicker = true } label: {
            artworkSquare(size: size)
        }
        .buttonStyle(.plain)
        #endif
    }

    private func artworkSquare(size: CGFloat) -> some View {
        ZStack {
            // Artwork or placeholder
            if let artworkData, let img = platformImage(from: artworkData) {
                img.resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mixSurface2)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.28))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }

            // Camera badge — bottom-right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - Name field

    private var nameFieldView: some View {
        TextField("Playlist name", text: $name)
            .font(.system(size: 14))
            .foregroundStyle(Color.mixTextPrimary)
            #if os(macOS)
            .textFieldStyle(.plain)
            #endif
            .padding(10)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Description field  (ZStack placeholder trick — TextEditor has no built-in placeholder)

    private var descriptionFieldView: some View {
        ZStack(alignment: .topLeading) {
            if description.isEmpty {
                Text("Add an optional description")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $description)
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
        }
        .frame(minHeight: 80)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimDesc = description.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        
        if let playlist = editingPlaylist {
            deps.libraryService.updatePlaylist(
                id:          playlist.id,
                name:        trimName,
                description: trimDesc.isEmpty ? nil : trimDesc,
                artworkData: artworkData
            )
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

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        guard let ui = UIImage(data: data)   else { return nil }
        return Image(uiImage: ui)
        #elseif os(macOS)
        guard let ns = NSImage(data: data)   else { return nil }
        return Image(nsImage: ns)
        #endif
    }
}

// MARK: - Preview

#Preview {
    PlaylistEditorSheet()
        .environmentObject(AppDependencies())
}
