// PlaylistInviteInbox.swift
// Mixtape — Features/Social
//
// The invitee's side of a direct invite: the cards that say "@alex invited you
// to Drizzy", with Accept and Decline.
//
// This exists because being invited used to be an event no device ever noticed.
// `addCollaborator` wrote the membership row and stopped there; nothing read
// `playlist_collaborators where user_id = me`, so an invite produced no
// notification, no card and no playlist. The only way in was for the owner to
// separately send a link.
//
// Nothing lands in the library until the invite is accepted. Adding a playlist
// to somebody's library because a third party pressed a button is how a library
// fills with things nobody chose — and the "Members update shared playlists"
// policy only trusts `status = 'joined'`, so the accept is a real gate rather
// than a courtesy.

import SwiftUI

struct PlaylistInviteInbox: View {

    /// Matched to the surrounding list's insets — 16 in the iOS library, 12 in
    /// the Mac playlists column — so the cards line up with the rows below them
    /// rather than floating in their own margin.
    var horizontalPadding: CGFloat = 16

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var sharing = PlaylistSharingService.shared

    @State private var busy: Set<UUID> = []

    var body: some View {
        if !sharing.pendingInvites.isEmpty {
            VStack(spacing: 8) {
                ForEach(sharing.pendingInvites) { invite in
                    card(invite)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .mixAnimation(.easeInOut(duration: 0.2), value: sharing.pendingInvites)
        }
    }

    // MARK: Card

    private func card(_ invite: PlaylistSharingService.PendingInvite) -> some View {
        let isBusy = busy.contains(invite.id)

        return HStack(alignment: .top, spacing: 12) {
            cover(invite)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline(invite))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)

                Text(invite.record.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)

                Text(subtitle(invite))
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Button {
                        Task { await respond(to: invite, accept: true) }
                    } label: {
                        Text("Accept")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixOnAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.mixAccentFill, in: Capsule())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .disabled(isBusy)

                    Button {
                        Task { await respond(to: invite, accept: false) }
                    } label: {
                        Text("Decline")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.mixSurface2, in: Capsule())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .disabled(isBusy)

                    if isBusy { ProgressView().controlSize(.small) }

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixPrimary.opacity(0.35), lineWidth: 1)
        )
    }

    /// The owner's published cover, straight out of the public bucket.
    ///
    /// `AsyncImage` rather than the app's `ArtworkThumbnail`, which takes `Data`:
    /// there is no local copy of this playlist yet — that's the entire point of
    /// the card — so the only picture available is the remote one.
    @ViewBuilder
    private func cover(_ invite: PlaylistSharingService.PendingInvite) -> some View {
        let side: CGFloat = 56
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.mixSurface2)
            if let url = invite.record.artworkURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderGlyph
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholderGlyph: some View {
        Image(systemName: MixtapeIcons.playlist)
            .font(.system(size: 20))
            .foregroundStyle(Color.mixTextTertiary)
    }

    private func headline(_ invite: PlaylistSharingService.PendingInvite) -> String {
        guard let name = invite.inviterName else { return "You've been invited to" }
        return "\(name) invited you to"
    }

    /// Song count comes from the snapshot, so the card can be honest about how
    /// big the thing being offered is before any of it is downloaded.
    private func subtitle(_ invite: PlaylistSharingService.PendingInvite) -> String {
        let count = invite.record.trackIds.count
        return "\(count) song\(count == 1 ? "" : "s") \u{00B7} you'll be able to add your own"
    }

    // MARK: Actions

    private func respond(to invite: PlaylistSharingService.PendingInvite, accept: Bool) async {
        busy.insert(invite.id)
        defer { busy.remove(invite.id) }

        do {
            try await sharing.respondToInvite(invite,
                                              accept: accept,
                                              libraryService: deps.libraryService)
            // A banner still sitting in Notification Centre for an invite that has
            // just been declined is a tap away from re-opening a decision the user
            // has already made.
            InviteNotifier.shared.clear(invite.id)
            if accept {
                deps.showToast("Joined \u{201C}\(invite.record.name)\u{201D}")
                // The playlist and its placeholder tracks were written locally by
                // `materialise`; this is what gets them onto the user's other
                // devices, the same way redeeming a link does.
                try? await deps.syncService.sync()
            } else {
                deps.showToast("Declined \u{201C}\(invite.record.name)\u{201D}")
            }
        } catch {
            // Nothing was added locally — the status write is the first thing
            // `respondToInvite` does — so the card is still here to try again.
            deps.showToast(accept ? "Couldn't join that playlist" : "Couldn't decline that invite")
        }
    }
}
