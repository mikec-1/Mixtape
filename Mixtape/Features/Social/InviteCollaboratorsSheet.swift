// "Invite collaborators to <playlist>": the owner's side of a shared playlist.
// Three ways in: a link (copied on open), a QR for someone in the room, or by username,
// which writes the membership row directly so no code is exposed.
// Runs against the existing RLS. The owner can add and remove anyone; an editor only sees
// the member list.

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct InviteCollaboratorsSheet: View {

    // MARK: Inputs

    /// The local playlist, when opened from the library. Opening this sheet publishes it.
    private let localPlaylist: Playlist?
    private let tracks: [Track]
    /// The shared row, when we came from a public playlist page and already know it.
    private let knownSharedID: UUID?
    /// Only used to repair the stored link, which a restore leaves with an empty share code.
    private let localPlaylistID: UUID?
    private let name: String
    private let coverData: Data?
    private let declaredOwner: Bool?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    // MARK: State

    @State private var sharedID: UUID?
    @State private var code: String?
    @State private var role = "owner"
    @State private var isPreparing = true
    @State private var errorText: String?

    @State private var members: [Member] = []
    @State private var isLoadingMembers = false

    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var isSearching = false
    @State private var invitedIDs: Set<UUID> = []
    @State private var busyIDs: Set<UUID> = []

    @State private var showsQR = false
    @State private var confirmRegenerate = false

    /// Two queries: `playlist_collaborators.user_id` points at `auth.users`, so PostgREST
    /// can't embed `profiles`.
    private struct Member: Identifiable, Hashable {
        let profile: UserProfile
        let role: String
        let status: PlaylistSharingService.InviteStatus
        var id: UUID { profile.id }
        var isOwner: Bool { role == "owner" }

        /// Whether they've taken it up. The role (always editor) only shows once joined.
        var standing: String {
            if isOwner { return "Owner" }
            switch status {
            case .joined:   return "Can add songs"
            case .invited:  return "Invited \u{00B7} waiting for a reply"
            case .declined: return "Declined the invite"
            }
        }

        var chip: (text: String, colour: Color)? {
            guard !isOwner else { return nil }
            switch status {
            case .joined:   return nil
            case .invited:  return ("Invited", .mixPrimary)
            case .declined: return ("Declined", .mixTextTertiary)
            }
        }
    }

    // MARK: Init

    /// From the library. Publishes on open; `shareToSupabase` is get-or-create.
    init(playlist: Playlist, tracks: [Track]) {
        self.localPlaylist   = playlist
        self.tracks          = tracks
        self.knownSharedID   = nil
        self.localPlaylistID = playlist.id
        self.name            = playlist.name
        self.coverData       = playlist.displayArtwork
        self.declaredOwner   = nil
    }

    /// From a public playlist page, where the row exists and the local copy may not.
    /// `isOwner` comes from the caller, which checked `owner_id`.
    init(sharedPlaylistID: UUID,
         localPlaylistID: UUID?,
         name: String,
         coverData: Data?,
         isOwner: Bool) {
        self.localPlaylist   = nil
        self.tracks          = []
        self.knownSharedID   = sharedPlaylistID
        self.localPlaylistID = localPlaylistID
        self.name            = name
        self.coverData       = coverData
        self.declaredOwner   = isOwner
    }

    private var isOwner: Bool { declaredOwner ?? (role == "owner") }

    private var inviteLink: String? {
        code.map { PlaylistSharingService.inviteURL(code: $0).absoluteString }
    }

    // MARK: Body

    var body: some View {
        MixSheet(title: isOwner ? "Invite" : "Collaborators",
                 subtitle: isOwner
                     ? "Anyone you invite can add and remove songs."
                     : "You're a collaborator on this playlist.",
                 size: .large) {
            content
        }
        .tint(Color.mixPrimary)
        .task { await prepare() }
    }

    @ViewBuilder
    private var content: some View {
        // No ScrollView or margins: the chrome owns both.
        VStack(alignment: .leading, spacing: 18) {
            playlistRow

            if isPreparing {
                loading
            } else if let errorText {
                failure(errorText)
            } else {
                if let link = inviteLink {
                    linkCard(link)
                    if showsQR { qrCard(link) }
                }
                if isOwner { inviteByUsername }
                memberList
                if isOwner, code != nil { regenerateRow }
            }
        }
    }

    // MARK: Playlist

    /// Which playlist this is about: cover and name.
    private var playlistRow: some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(data: coverData,
                             size: 56,
                             cornerRadius: 8,
                             placeholder: MixtapeIcons.playlist)

            Text(name)
                .font(.system(size: MixFontScale.size(15), weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Preparing invite\u{2026}")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(Color.mixTextTertiary)
            Text(message)
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: Link

    /// The link is already copied on open; this card confirms it.
    private func linkCard(_ link: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite link")
                .font(.mixCaptionBold)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.mixTextSecondary)

            Text(link)
                .font(.system(size: MixFontScale.size(13), weight: .medium, design: .monospaced))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                actionChip("Copy", icon: "doc.on.doc") {
                    copyToClipboard(link)
                    deps.showToast(.done("Invite link copied"))
                }

                ShareLink(item: link,
                          subject: Text("Join \"\(name)\" on Mixtape"),
                          message: Text("Join my playlist \"\(name)\" on Mixtape.")) {
                    chipLabel("Share", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain).mixHandCursor()

                actionChip(showsQR ? "Hide QR" : "QR code", icon: "qrcode") {
                    withMixAnimation(.easeInOut(duration: 0.2)) { showsQR.toggle() }
                }

                Spacer(minLength: 0)
            }

            if let code {
                Divider().overlay(Color.mixSeparator)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Or give them the code")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)

                    HStack(spacing: 12) {
                        Text(code)
                            .font(.system(size: MixFontScale.size(26), weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Color.mixTextPrimary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)

                        actionChip("Copy", icon: "doc.on.doc") {
                            copyToClipboard(code)
                            deps.showToast(.done("Code copied"))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        )
    }

    /// For a Mac: the invitee can scan the screen with their phone.
    private func qrCard(_ link: String) -> some View {
        VStack(spacing: 10) {
            if let image = Self.qrImage(for: link) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Point a camera at this to join.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            } else {
                Text("Couldn't draw a QR code for this link.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Invite by username

    /// Writes the membership row directly, so there's no code to leak.
    private var inviteByUsername: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Invite someone")
                .font(.mixCaptionBold)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.mixTextSecondary)

            HStack(spacing: 8) {
                Image(systemName: MixtapeIcons.search)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)

                TextField("Search by username", text: $query)
                    .textFieldStyle(.plain)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ForEach(results) { profile in
                inviteRow(profile)
            }

            if !isSearching, results.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("No one found with that username.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.leading, 2)
            }
        }
        .task(id: query) { await search() }
    }

    private func inviteRow(_ profile: UserProfile) -> some View {
        // Someone who declined can be invited again.
        let alreadyIn = members.contains { $0.id == profile.id && $0.status != .declined }
            || invitedIDs.contains(profile.id)
        let isBusy    = busyIDs.contains(profile.id)

        return HStack(spacing: 10) {
            AvatarView(url: profile.avatarURL, fallbackText: profile.username, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text("@\(profile.username)")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if alreadyIn {
                Label("Added", systemImage: MixtapeIcons.checkmark)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextTertiary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button {
                    Task { await invite(profile) }
                } label: {
                    Text("Invite")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.mixAccentFill, in: Capsule())
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.mixSurface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Members

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("People")
                    .font(.mixCaptionBold)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Color.mixTextSecondary)
                if isLoadingMembers { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }

            if members.isEmpty && !isLoadingMembers {
                Text("No one else yet. Send the link.")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.leading, 2)
            }

            ForEach(members) { member in
                memberRow(member)
            }
        }
    }

    private func memberRow(_ member: Member) -> some View {
        HStack(spacing: 10) {
            AvatarView(url: member.profile.avatarURL,
                       fallbackText: member.profile.username,
                       size: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.profile.name)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)

                    if let chip = member.chip {
                        Text(chip.text)
                            .font(.system(size: MixFontScale.size(10), weight: .bold))
                            .foregroundStyle(chip.colour)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(chip.colour.opacity(0.15), in: Capsule())
                    }
                }
                Text("@\(member.profile.username) · \(member.standing)")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }

            Spacer(minLength: 8)

            if busyIDs.contains(member.id) {
                ProgressView().controlSize(.small)
            } else if isOwner && !member.isOwner {
                Button {
                    Task { await remove(member) }
                } label: {
                    Image(systemName: MixtapeIcons.close)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Remove @\(member.profile.username)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Regenerate

    private var regenerateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirmRegenerate = true
            } label: {
                Label("Reset invite link", systemImage: "arrow.triangle.2.circlepath")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .buttonStyle(.plain).mixHandCursor()

            Text("Stops anyone using the old link or code. People already here stay.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .mixConfirmationDialog("Reset the invite link?",
                            isPresented: $confirmRegenerate,
                            titleVisibility: .visible) {
            Button("Reset Link", role: .destructive) {
                Task { await regenerate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current link and code stop working. Anyone who has already joined keeps access.")
        }
    }

    // MARK: Chips

    private func actionChip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, icon: icon) }
            .buttonStyle(.plain).mixHandCursor()
    }

    private func chipLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: MixFontScale.size(11), weight: .semibold))
            Text(title).font(.mixLabel)
        }
        .foregroundStyle(Color.mixPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.mixPrimary.opacity(0.12), in: Capsule())
    }

    // MARK: Actions

    /// Resolves the shared row and its code, then copies the link. Publishes if needed.
    private func prepare() async {
        guard isPreparing else { return }
        defer { isPreparing = false }

        let service = PlaylistSharingService.shared

        do {
            if let playlist = localPlaylist {
                let link = service.linkedShare(forLocalPlaylist: playlist.id)

                if let link, link.role != "owner" {
                    // Joined from someone else's code: read, don't publish a competing row.
                    role     = link.role
                    sharedID = link.sharedPlaylistID
                    code     = link.shareCode.isEmpty
                        ? try await service.inviteCode(forSharedPlaylist: link.sharedPlaylistID,
                                                       localPlaylistID: playlist.id)
                        : link.shareCode
                } else {
                    role     = "owner"
                    code     = try await service.shareToSupabase(playlist: playlist,
                                                                 tracks: tracks,
                                                                 deviceID: AppDependencies.deviceID)
                    sharedID = service.linkedShare(forLocalPlaylist: playlist.id)?.sharedPlaylistID
                }
            } else if let known = knownSharedID {
                sharedID = known
                role     = localPlaylistID
                    .flatMap { service.linkedShare(forLocalPlaylist: $0)?.role } ?? "owner"
                code     = try await service.inviteCode(forSharedPlaylist: known,
                                                        localPlaylistID: localPlaylistID)
            }
        } catch {
            errorText = friendlyInviteMessage(error)
            return
        }

        if let link = inviteLink, isOwner {
            copyToClipboard(link)
            deps.showToast(.done("Invite link copied"))
        }

        await loadMembers()
    }

    private func loadMembers() async {
        guard let sharedID else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }

        guard let rows = try? await PlaylistSharingService.shared.collaborators(sharedPlaylistID: sharedID)
        else { return }

        var resolved: [Member] = []
        for row in rows {
            guard let profile = try? await deps.authService.fetchProfile(id: row.userID) else { continue }
            resolved.append(Member(profile: profile, role: row.role, status: row.status))
        }
        // The owner has no collaborator row, so add ourselves. Fetched rather than built from
        // `currentUser`, whose `displayName` can fall back to the email.
        if isOwner, let me = deps.authService.currentUser {
            let profile = (try? await deps.authService.fetchProfile(id: me.id))
                ?? UserProfile(id: me.id, username: me.username ?? me.displayName, displayName: me.displayName, avatarURL: me.avatarURL)
            resolved.removeAll { $0.id == me.id }
            resolved.insert(Member(profile: profile, role: "owner", status: .joined), at: 0)
        }
        members = resolved
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        // Typing "michael" shouldn't be seven queries.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }
        results = (try? await deps.authService.searchUsers(matching: trimmed, limit: 12)) ?? []
    }

    private func invite(_ profile: UserProfile) async {
        guard let sharedID else { return }
        busyIDs.insert(profile.id)
        defer { busyIDs.remove(profile.id) }

        do {
            let outcome = try await PlaylistSharingService.shared
                .addCollaborator(userID: profile.id, toSharedPlaylist: sharedID)
            invitedIDs.insert(profile.id)
            switch outcome {
            case .invited, .reinvited:
                deps.showToast(.done("Invited @\(profile.username)"))
            case .alreadyMember:
                deps.showToast("@\(profile.username) is already in this playlist")
            case .alreadyInvited:
                deps.showToast("@\(profile.username) has already been invited")
            }
            await loadMembers()
        } catch {
            deps.showToast(.failed("Couldn't invite @\(profile.username)", error))
        }
    }

    private func remove(_ member: Member) async {
        guard let sharedID else { return }
        busyIDs.insert(member.id)
        defer { busyIDs.remove(member.id) }

        do {
            try await PlaylistSharingService.shared.removeCollaborator(userID: member.id,
                                                                       fromSharedPlaylist: sharedID)
            invitedIDs.remove(member.id)
            members.removeAll { $0.id == member.id }
            deps.showToast(.done("Removed @\(member.profile.username)"))
        } catch {
            deps.showToast(.failed("Couldn't remove @\(member.profile.username)", error))
        }
    }

    private func regenerate() async {
        guard let sharedID else { return }
        do {
            code = try await PlaylistSharingService.shared
                .regenerateShareCode(forSharedPlaylist: sharedID, localPlaylistID: localPlaylistID)
            if let link = inviteLink { copyToClipboard(link) }
            deps.showToast(.done("New invite link copied"))
        } catch {
            deps.showToast(.failed("Couldn't reset the link", error))
        }
    }

    // MARK: QR

    /// Needs `.interpolation(.none)` at the call site; a smoothed QR won't scan.
    static func qrImage(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }

        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: cg,
                                      size: NSSize(width: scaled.extent.width,
                                                   height: scaled.extent.height)))
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }
}

// MARK: - Helpers

private func friendlyInviteMessage(_ error: Error) -> String {
    if let sharing = error as? PlaylistSharingService.SharingError {
        return sharing.errorDescription ?? "Something went wrong."
    }
    return "You need to be signed in to invite people to a playlist."
}
