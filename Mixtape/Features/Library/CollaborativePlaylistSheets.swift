// CollaborativePlaylistSheets.swift
// Mixtape — Features/Library
//
// UI for collaborative playlists, backed by PlaylistSharingService + the
// 20260613_collaborative_playlists.sql Supabase schema.
//
//   • ShareCollaborativeSheet — publishes a playlist and shows a join code.
//   • JoinSharedPlaylistSheet — redeems a code and materialises a local copy.
//
// Both require the user to be signed in (Supabase session). Realtime two-way
// editing is deferred; joining creates a local snapshot of the shared track list.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Share

struct ShareCollaborativeSheet: View {

    let playlist: Playlist
    let tracks: [Track]

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var shareCode: String?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()
                VStack(spacing: 20) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.mixPrimary)
                        .padding(.top, 12)

                    Text("Share \"\(playlist.name)\"")
                        .font(.mixTitle2)
                        .foregroundStyle(Color.mixTextPrimary)
                        .multilineTextAlignment(.center)

                    if let shareCode {
                        codeCard(shareCode)
                    } else {
                        Text("Create a share code others can use to add this playlist and follow its track list.")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Button {
                            Task { await share() }
                        } label: {
                            HStack {
                                if isLoading { ProgressView().controlSize(.small) }
                                Text("Create share code")
                                    .font(.mixBodyBold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.mixPrimary)
                            )
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                        .padding(.horizontal, 24)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixDestructive)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Spacer()
                }
                .padding(.top, 8)
            }
            .navigationTitle("Collaborate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Color.mixPrimary)
    }

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 14) {
            Text(code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.mixTextPrimary)
                .tracking(4)

            HStack(spacing: 12) {
                ShareLink(item: "Join my Mixtape playlist \"\(playlist.name)\" with code: \(code)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.mixBodyBold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.mixPrimary)

                Button {
                    copyToClipboard(code)
                    deps.showToast("Code copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.mixBodyBold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.mixPrimary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface)
        )
        .padding(.horizontal, 24)
    }

    private func share() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let code = try await PlaylistSharingService.shared.shareToSupabase(
                playlist: playlist,
                tracks: tracks,
                deviceID: AppDependencies.deviceID
            )
            shareCode = code
        } catch {
            errorText = friendlyMessage(error)
        }
    }
}

// MARK: - Join

struct JoinSharedPlaylistSheet: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()
                VStack(spacing: 20) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.mixPrimary)
                        .padding(.top, 12)

                    Text("Join a Shared Playlist")
                        .font(.mixTitle2)
                        .foregroundStyle(Color.mixTextPrimary)

                    Text("Enter the code someone shared with you.")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)

                    TextField("Share code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .tracking(4)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.mixSurface)
                        )
                        .padding(.horizontal, 24)

                    Button {
                        Task { await join() }
                    } label: {
                        HStack {
                            if isLoading { ProgressView().controlSize(.small) }
                            Text("Join")
                                .font(.mixBodyBold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canJoin ? Color.mixPrimary : Color.mixSurface2)
                        )
                        .foregroundStyle(canJoin ? Color.white : Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canJoin || isLoading)
                    .padding(.horizontal, 24)

                    if let errorText {
                        Text(errorText)
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixDestructive)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Spacer()
                }
                .padding(.top, 8)
            }
            .navigationTitle("Join")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Color.mixPrimary)
    }

    private var canJoin: Bool {
        code.trimmingCharacters(in: .whitespaces).count >= 4
    }

    private func join() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        do {
            let record = try await PlaylistSharingService.shared.joinSharedPlaylist(shareCode: trimmed)
            materialize(record)
            deps.showToast("Joined \"\(record.name)\"")
            dismiss()
        } catch {
            errorText = friendlyMessage(error)
        }
    }

    /// Create a local snapshot playlist mirroring the shared one. EVERY shared track is
    /// added: tracks the joining user already has locally are linked directly, and
    /// tracks they don't have are imported as unavailable placeholders (from the shared
    /// metadata snapshot) so the playlist isn't empty. The local↔shared association is
    /// persisted so future opens can re-pull updates (Issue 3). Two-way realtime sync
    /// of the shared list remains a deferred follow-up.
    private func materialize(_ record: PlaylistSharingService.SharedPlaylistRecord) {
        let local = deps.libraryService.createPlaylist(
            name: record.name,
            description: record.description
        )

        // Reconcile the new local playlist's track list to exactly match the shared
        // snapshot, importing placeholders for any songs not present locally.
        deps.libraryService.reconcileSharedPlaylist(
            localPlaylistID: local.id,
            remoteTrackIDs: record.trackIds,
            remoteTrackMeta: record.tracks
        )

        // Persist the link so refreshSharedPlaylist can re-pull/reconcile later.
        PlaylistSharingService.shared.setLinkedShare(
            PlaylistSharingService.LinkedShare(
                sharedPlaylistID: record.id,
                shareCode: record.shareCode,
                role: "editor"
            ),
            forLocalPlaylist: local.id
        )
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

private func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
