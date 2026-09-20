// CollaborativePlaylistSheets.swift
// Mixtape — Features/Library
//
// JoinSharedPlaylistSheet — redeems a share code and materialises a local copy.
// Backed by PlaylistSharingService + 20260613_collaborative_playlists.sql.
//
// The other half of this file used to be ShareCollaborativeSheet, which showed a
// code and stopped there; it now lives in Features/Social as
// InviteCollaboratorsSheet, which does links, QR and by-username invites too.
// Typing a code stays because it's the fallback the link can't replace — read
// down a phone, or copied out of a message that stripped the URL.
//
// Requires a Supabase session. Joining takes a snapshot of the shared track list;
// changes flow both ways on open and on edit, but not live.

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
        // The title used to be the single word "Join" in a navigation bar, with
        // the real heading repeated underneath in the content — and a 44pt
        // glyph above both. One title, in the one place a title goes.
        MixSheet(title: "Join a Shared Playlist",
                 subtitle: "Enter the code someone shared with you.",
                 size: .compact,
                 primary: MixSheetAction("Join",
                                         isEnabled: canJoin,
                                         isBusy: isLoading,
                                         action: { Task { await join() } })) {
            VStack(alignment: .leading, spacing: 12) {
                // The code is the whole sheet, so it gets to be the big thing —
                // monospaced and tracked out so six characters read as six
                // characters rather than as a word.
                TextField("Share code", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
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

    /// Materialising the playlist lives in the service now, because a
    /// `mixtape://join` link has to do exactly the same thing and there is no
    /// version of "exactly the same thing" that survives being written twice.
    private func join() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await PlaylistSharingService.shared
                .redeemInvite(code: code, libraryService: deps.libraryService)
            deps.showToast(result.alreadyHere
                           ? "\u{201C}\(result.record.name)\u{201D} is already in your library"
                           : "Joined \u{201C}\(result.record.name)\u{201D}")
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
