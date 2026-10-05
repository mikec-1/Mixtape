// JoinSharedPlaylistSheet: redeems a share code and makes a local copy.
// Backed by PlaylistSharingService + 20260613_collaborative_playlists.sql.
// Inviting lives in Features/Social (InviteCollaboratorsSheet). Typing a code
// stays as the fallback for when there's no link.
// Needs a Supabase session. Joining snapshots the track list; changes sync on open
// and edit, not live.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Join

struct JoinSharedPlaylistSheet: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        MixSheet(title: "Join a Shared Playlist",
                 subtitle: "Enter the code someone shared with you.",
                 size: .compact,
                 primary: MixSheetAction("Join",
                                         isEnabled: canJoin,
                                         isBusy: isLoading,
                                         action: { Task { await join() } })) {
            VStack(alignment: .leading, spacing: 12) {
                // Monospaced and tracked out so the code reads character by character.
                TextField("Share code", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: MixFontScale.size(22), weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(.center)
                    .tracking(4)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    #endif
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color.mixSurface2,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let errorText {
                    MixSheetStatus(kind: .failure, title: "Couldn't join", detail: errorText)
                }
            }
        }
        .tint(Color.mixPrimary)
    }

    private var canJoin: Bool {
        code.trimmingCharacters(in: .whitespaces).count >= 4
    }

    /// The service does the joining, shared with `mixtape://join` links.
    private func join() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await PlaylistSharingService.shared
                .redeemInvite(code: code, libraryService: deps.libraryService)
            let id = result.localPlaylistID
            deps.showToast(Toast.done(result.alreadyHere
                                      ? "\u{201C}\(result.record.name)\u{201D} is already in your library"
                                      : "Joined \u{201C}\(result.record.name)\u{201D}")
                .action("View") { Toast.openPlaylist(id) })
            dismiss()
        } catch {
            errorText = friendlyMessage(error)
        }
    }
}

// MARK: - Shared helpers

private func friendlyMessage(_ error: Error) -> String {
    if let sharing = error as? PlaylistSharingService.SharingError {
        return sharing.errorDescription ?? "Something went wrong."
    }
    // Most commonly: not signed in (no Supabase session).
    return "You need to be signed in to share or join playlists. \(error.localizedDescription)"
}
