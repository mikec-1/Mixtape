// InviteCollaboratorsSheet.swift
// Mixtape — Features/Social
//
// "Invite collaborators to <playlist>" — the owner's side of a shared playlist.
//
// Replaces ShareCollaborativeSheet, which showed a 6-character code and nothing
// else. The code still exists and is still the thing being redeemed, but it is no
// longer the interface: a link you can send is, and the code is what's left when
// the link can't travel — read down a phone, typed off a screen.
//
// Three ways in, because there is no one channel that works for everyone:
//   • the link, copied on open and shareable through the system sheet
//   • the QR, for the person standing next to you while you're on a Mac
//   • by username, which hands out nothing at all — the owner writes the
//     membership row directly, so no code is ever exposed
//
// Everything here runs against the RLS already in place (20260613 + the 20260807
// policy rewrite). The owner may add and remove anyone; an editor who opens this
// gets the member list and nothing else, which is the honest read of what the
// policies let them do.

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

    /// The local playlist, when we came from the library. Its shared row may not
    /// exist yet — opening this sheet is what publishes it.
    private let localPlaylist: Playlist?
    private let tracks: [Track]
    /// The shared row, when we came from a public playlist page and already know it.
    private let knownSharedID: UUID?
    /// The local copy's id, if this device has one. Only used to repair the stored
    /// link, which a restore leaves holding an empty share code.
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

    /// A collaborator with their profile resolved. Two queries rather than one:
    /// `playlist_collaborators.user_id` points at `auth.users`, so there's no
    /// foreign key for PostgREST to embed `profiles` through.
    private struct Member: Identifiable, Hashable {
        let profile: UserProfile
        let role: String
        let status: PlaylistSharingService.InviteStatus
        var id: UUID { profile.id }
        var isOwner: Bool { role == "owner" }

        /// What the owner is actually asking when they open this list: has this
        /// person taken it up? The role is the less interesting half — everyone
        /// invited is an editor — so it only gets said when the answer is yes.
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

    /// From the library. Publishing on open is deliberate — a playlist you're
    /// inviting someone to has to exist server-side before the invite means
    /// anything, and `shareToSupabase` is get-or-create, so re-opening is free.
    init(playlist: Playlist, tracks: [Track]) {
        self.localPlaylist   = playlist
        self.tracks          = tracks
        self.knownSharedID   = nil
        self.localPlaylistID = playlist.id
        self.name            = playlist.name
        self.coverData       = playlist.displayArtwork
        self.declaredOwner   = nil
    }

    /// From a public playlist page, where the row is known to exist and the local
    /// copy may not. `isOwner` comes from the caller because the page already
    /// answered it against `owner_id`, and re-deriving it here from a stored link
    /// would get it wrong on a device that has never had the playlist.
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
        // The sentence that used to sit under the playlist name is the sheet's
        // subtitle now — it describes the sheet, not the playlist, so it was
        // being said in the wrong place and at the wrong size.
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
        // No ScrollView and no margins here — the chrome owns both, which is
        // what lets the header hairline know when this has scrolled under it.
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

    /// Which playlist this is about. Just the cover and the name — the
    /// explanation moved up into the sheet's own subtitle.
    private var playlistRow: some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(data: coverData,
                             size: 56,
                             cornerRadius: 8,
                             placeholder: MixtapeIcons.playlist)

            Text(name)
                .font(.system(size: 15, weight: .semibold))
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

    /// The link is copied the moment this sheet opens, so this card is confirming
    /// something that already happened rather than offering it. Spotify copies
    /// silently on click; doing only that leaves you unsure whether it worked.
    private func linkCard(_ link: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite link")
                .font(.mixCaptionBold)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.mixTextSecondary)

            Text(link)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                    deps.showToast("Invite link copied")
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
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Color.mixTextPrimary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)

                        actionChip("Copy", icon: "doc.on.doc") {
                            copyToClipboard(code)
                            deps.showToast("Code copied")
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

    /// Chiefly for a Mac: the person you want to invite is in the room, and
    /// pointing a phone at the screen beats reading six characters aloud.
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

    /// The only path here that hands out nothing. A link can be forwarded to
    /// anyone; this writes the membership row directly, so there's no code in
    /// flight to leak and nothing to regenerate afterwards.
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
        // Someone who declined is deliberately still invitable — that's a "no" to
        // one invite, not a standing refusal, and the alternative is an owner
        // staring at a greyed-out "Added" for a person who isn't in the playlist.
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
                // Not "In this playlist" any more: the list now also holds people
                // who have been asked and people who said no, and calling those
                // "in" is the sort of thing that makes an owner re-invite someone
                // who is already there.
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
                            .font(.system(size: 10, weight: .bold))
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
        .confirmationDialog("Reset the invite link?",
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
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(.mixLabel)
        }
        .foregroundStyle(Color.mixPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.mixPrimary.opacity(0.12), in: Capsule())
    }

    // MARK: Actions

    /// Resolves the shared row and its code, then copies the link. Publishing here
    /// is what makes "Invite" work on a playlist that has never left this device.
    private func prepare() async {
        guard isPreparing else { return }
        defer { isPreparing = false }

        let service = PlaylistSharingService.shared

        do {
            if let playlist = localPlaylist {
                let link = service.linkedShare(forLocalPlaylist: playlist.id)

                if let link, link.role != "owner" {
                    // Joined from someone else's code. Publishing would mint a
                    // second, competing row owned by *us* for a playlist that
                    // isn't ours — so read, don't write.
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
            deps.showToast("Invite link copied")
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
        // The owner has no collaborator row — ownership lives on the shared row
        // itself — so on our own playlist we're missing from our own member list.
        // Our profile is fetched rather than built from `currentUser`, whose
        // `displayName` falls back to the email when no name is set; everyone
        // else in this list is an @username, and one row reading "@mike@gmail.com"
        // would look like a different kind of thing entirely.
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
                deps.showToast("Invited @\(profile.username)")
            case .alreadyMember:
                deps.showToast("@\(profile.username) is already in this playlist")
            case .alreadyInvited:
                deps.showToast("@\(profile.username) has already been invited")
            }
            await loadMembers()
        } catch {
            deps.showToast("Couldn't invite @\(profile.username)")
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
            deps.showToast("Removed @\(member.profile.username)")
        } catch {
            deps.showToast("Couldn't remove @\(member.profile.username)")
        }
    }

    private func regenerate() async {
        guard let sharedID else { return }
        do {
            code = try await PlaylistSharingService.shared
                .regenerateShareCode(forSharedPlaylist: sharedID, localPlaylistID: localPlaylistID)
            if let link = inviteLink { copyToClipboard(link) }
            deps.showToast("New invite link copied")
        } catch {
            deps.showToast("Couldn't reset the link")
        }
    }

    // MARK: QR

    /// `.interpolation(.none)` at the call site matters as much as this does — a
    /// smoothed QR is a blurry QR, and cameras stop reading it.
    private static func qrImage(for string: String) -> Image? {
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
