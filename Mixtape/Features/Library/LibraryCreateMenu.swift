// LibraryCreateMenu.swift
// Mixtape — Features/Library
//
// The + menu in Your Library: one place for every way of putting a new playlist
// on the page.
//
// These used to be permanent rows pinned above the playlist list — "Smart
// Playlists" and "Join Shared Playlist" — which cost two rows of the first
// screen forever to advertise things you do once in a while, and floated over
// the playlists scrolling underneath them. They're actions, not shelves, so
// they live behind the + the way Spotify's Playlist / Blend / Folder menu does.

import SwiftUI

// MARK: - Route

/// What the + menu was asked for. Presented by the caller *after* the menu
/// dismisses — stacking a sheet on a sheet that's still on its way out is how
/// you get a screen with nothing on it.
enum LibraryCreateRoute: String, Identifiable {
    case playlist
    case smartPlaylist
    case generateMix
    case joinShared
    case importSongs

    var id: String { rawValue }
}

// MARK: - Menu

struct LibraryCreateMenu: View {

    /// Called with the chosen route; the sheet dismisses itself first.
    let onSelect: (LibraryCreateRoute) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Add to your library")
                    .font(.mixTitle2)
                    .foregroundStyle(Color.mixTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 14)

                row(.playlist,
                    icon: "music.note.list",
                    title: "Playlist",
                    subtitle: "Build one by hand from your songs")

                row(.smartPlaylist,
                    icon: "wand.and.stars",
                    title: "Smart Playlist",
                    subtitle: "Set a rule and it keeps itself up to date")

                row(.generateMix,
                    icon: "sparkles",
                    title: "Generate a Mix",
                    subtitle: "Pick a vibe and blend your library with new music")

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)

                row(.joinShared,
                    icon: "person.badge.plus",
                    title: "Join Shared Playlist",
                    subtitle: "Enter a code someone sent you")

                row(.importSongs,
                    icon: MixtapeIcons.importFile,
                    title: "Import Songs",
                    subtitle: "Add music files from this device")

                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)
        }
        .presentationDetents([.height(Self.sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.mixBackground)
        .presentationCornerRadius(24)
    }

    /// Title block + four rows + the divider between the two halves, plus the
    /// home-indicator strip, which counts towards the detent but isn't space
    /// the content can use. Fixed rather than measured: the options are a known
    /// set, and a detent that resizes itself as the rows render reads as a
    /// glitch. Any slack lands on the trailing `Spacer`.
    private static let sheetHeight: CGFloat = 58 + (5 * 68) + 25 + 12 + 34

    private func row(_ route: LibraryCreateRoute,
                     icon: String,
                     title: String,
                     subtitle: String) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(route)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.mixSurface2)
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.mixPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(subtitle)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(height: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - Preview

#Preview {
    Color.mixBackground
        .sheet(isPresented: .constant(true)) {
            LibraryCreateMenu { _ in }
        }
}
