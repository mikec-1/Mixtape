// The + menu in Your Library: every way to add a playlist.

import SwiftUI

// MARK: - Route

/// What the + menu picked. The caller presents it once the menu has dismissed,
/// since stacking sheets mid-dismiss shows a blank screen.
enum LibraryCreateRoute: String, Identifiable {
    case playlist
    case smartPlaylist
    case crate
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

                row(.crate,
                    icon: "square.stack.3d.up",
                    title: "Crate",
                    subtitle: "Keep playlists, albums and artists together")

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

    /// Title, rows, divider and home-indicator strip. Fixed so the detent doesn't
    /// resize while rendering; slack goes to the trailing `Spacer`.
    private static let sheetHeight: CGFloat = 58 + (6 * 68) + 25 + 12 + 34

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
