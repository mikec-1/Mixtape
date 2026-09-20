// PublicPlaylistPage.swift
// Mixtape — Features/Social
//
// Somebody else's public playlist, read-only.
//
// It used to be a 460×520 sheet with hand-rolled rows, which made the one place
// you go to look at a *playlist* the one place that looked nothing like the
// playlist screen. This is the same page shape as PlaylistDetailView — the
// shared DetailHero, the same column table — with everything a visitor has no
// business doing taken out.
//
// What's gone, and why: no play or shuffle, because these are the owner's files
// and a visitor has none of them; no edit, no delete, no cover picker, no
// visibility toggle, because none of it is theirs to change. What's left is the
// one thing a visitor actually wants — a copy in their own library.
//
// Reusing PlaylistDetailView with a read-only flag was the other option and a
// worse one: it's a thousand lines wired to a local Playlist, the engine, the
// download manager, favourites and the public toggle, and every one of those
// would need a branch for a playlist that exists only as a published snapshot.

import Foundation
import SwiftUI

// MARK: - Navigation target

/// A public playlist plus whose it is. macOS routes through this because the
/// owner's handle is on the page and on its back button, and the summary alone
/// doesn't carry it.
public struct PublicPlaylistTarget: Identifiable, Hashable, Sendable {
    public let summary: PublicPlaylistSummary
    public let ownerName: String

    public var id: UUID { summary.id }

    public init(summary: PublicPlaylistSummary, ownerName: String) {
        self.summary = summary
        self.ownerName = ownerName
    }
}

// MARK: - Page

public struct PublicPlaylistPage: View {

    private let summary: PublicPlaylistSummary
    private let ownerName: String

    @EnvironmentObject private var deps: AppDependencies

    @StateObject private var artwork = ProfileArtworkStore()

    /// The cover as bytes. Resolved through `ProfileArtworkStore` and then
    /// downloaded if it came back as a URL, because the same image feeds the
    /// colour wash and the copy saved to the library — and both need real bytes,
    /// not a link.
    @State private var cover: Data?
    /// Set the moment the playlist is written to the library. There is no
    /// "adding…" state any more to go with it — saving is a local write now, so
    /// there is no interval to show a spinner in.
    @State private var didAdd = false
    /// Measured so the table drops columns it can't fit rather than crushing
    /// them, exactly as the library's own playlist table does.
    @State private var listWidth: CGFloat = 0

    @State private var showInvite = false
    /// Shown in the metadata line, and only ever loaded for our own playlist —
    /// the collaborator policies return nothing to a visitor, so asking would be
    /// a round trip that always answers zero.
    @State private var collaboratorCount = 0
    /// How many people are holding this playlist. Nil while unknown — before the
    /// first read, or on a server without `get_playlist_save_count` — and the
    /// header shows nothing at all rather than claiming zero.
    @State private var saveCount: Int?
    @State private var isHiding = false
    @State private var actionError: String?

    public init(summary: PublicPlaylistSummary, ownerName: String) {
        self.summary = summary
        self.ownerName = ownerName
    }

    private var columns: PublicTrackColumns { PublicTrackColumns(width: listWidth) }

    /// What the single button on this page is for.
    private enum LibraryState {
        /// Here already — your own row, or a copy you adopted earlier.
        case present
        /// Yours, still published, and not in this library. See `save()`.
        case missing
        /// Somebody else's, and you don't have it.
        case absent
    }

    /// Whether the signed-in viewer is the one who published this.
    ///
    /// Ownership is a fact about the row, not about this device. `summary.playlistID`
    /// names a playlist in the owner's library, and that playlist can be absent
    /// here — an account switch, a restore from an older backup — while the
    /// published row is still, plainly, theirs. Answering from presence alone is
    /// what had your own profile offering to add your own playlist.
    private var isMine: Bool {
        guard let ownerID = summary.ownerID,
              let viewer = deps.authService.currentUser?.id
        else { return false }
        return ownerID == viewer
    }

    /// Two ways this playlist can already be here, and they are not the same one.
    ///
    /// `summary.playlistID` is the OWNER's local id — it matches only on your own
    /// profile. A copy adopted from someone else got a fresh uuid at creation and
    /// shares nothing with the original, so it has to be found through the link
    /// recorded when it was added. Checking only the first is why the button kept
    /// offering to add a playlist that was already sitting in the sidebar, twice.
    private var libraryState: LibraryState {
        if didAdd || localCopyID != nil { return .present }
        return isMine ? .missing : .absent
    }

    /// This device's copy of the playlist, under either of the two ids it can
    /// have. Nil means there genuinely isn't one — which is the only thing that
    /// should ever put "Restore to Library" in front of the owner.
    private var localCopyID: UUID? {
        if deps.libraryService.playlist(id: summary.playlistID) != nil { return summary.playlistID }
        // The link outlives the playlist — someone can add a copy and then delete
        // it, and a stale link would leave the button permanently disabled.
        if let localID = PlaylistSharingService.shared.localPlaylistID(forSharedPlaylist: summary.id),
           deps.libraryService.playlist(id: localID) != nil {
            return localID
        }
        return nil
    }

    // MARK: Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // Demoted from the primary button it used to be. On your own
                // profile the thing you came to do is share the playlist, not
                // repair a device that's missing it — so restoring says its piece
                // here and gets out of the way of Invite.
                if isMine, libraryState == .missing, !summary.tracks.isEmpty {
                    restoreNote
                        .padding(.horizontal, Metrics.inset)
                        .padding(.top, 20)
                }

                if summary.tracks.isEmpty {
                    unpublishedNote
                        .padding(.horizontal, Metrics.inset)
                        .padding(.top, 24)
                } else {
                    if columns.isTable {
                        PublicTrackListHeader(columns: columns)
                            .padding(.horizontal, Metrics.inset)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(summary.tracks.enumerated()), id: \.element.id) { index, track in
                            PublicTrackRow(track: track,
                                           index: index + 1,
                                           columns: columns,
                                           artwork: deps.libraryService.track(id: track.id)?.displayArtwork,
                                           remoteArtwork: summary.trackArtworkURL(track.id))
                        }
                    }
                    .padding(.horizontal, Metrics.inset)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { listWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in listWidth = width }
                }
            }
        }
        .artworkWash(source: cover)
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(summary.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: summary.id) { await load() }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await loadCollaborators() } }) {
            InviteCollaboratorsSheet(sharedPlaylistID: summary.id,
                                     localPlaylistID: localCopyID,
                                     name: summary.name,
                                     coverData: cover,
                                     isOwner: isMine)
                .environmentObject(deps)
        }
        .alert("Couldn't do that",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        DetailHero(
            eyebrow: "Public Playlist",
            title: summary.name,
            subtitle: summary.description,
            metadata: metadataLine
        ) { size in
            ArtworkThumbnail(data: cover,
                             size: size,
                             cornerRadius: 14,
                             placeholder: MixtapeIcons.playlist)
        } actions: {
            if isMine { ownerActions } else { visitorActions }
        }
    }

    /// Whose it is comes first — it's the fact that makes this page different
    /// from the identical-looking one in your own library.
    private var metadataLine: String {
        let count = max(summary.trackCount, summary.tracks.count)
        var parts = ["@\(ownerName)", "\(count) song\(count == 1 ? "" : "s")"]
        if !summary.tracks.isEmpty { parts.append(totalDuration) }
        if collaboratorCount > 0 {
            parts.append("\(collaboratorCount) collaborator\(collaboratorCount == 1 ? "" : "s")")
        }
        if let saves = saveCount, saves > 0 {
            parts.append("\(saves) save\(saves == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var totalDuration: String {
        let secs = Int(summary.tracks.map(\.duration).reduce(0, +))
        if secs >= 3600 { return "\(secs / 3600) hr \((secs % 3600) / 60) min" }
        return "\(secs / 60) min"
    }

    // MARK: Owner actions

    /// What the owner gets instead of an add button, and the point of this whole
    /// screen for them: Spotify's plus button, which is an invite and nothing else.
    ///
    /// The previous primary action here was "Restore to Library" — an offer to
    /// re-download your own playlist, sitting where the only genuinely useful
    /// control belongs. Restore still exists (in the overflow, and as a note under
    /// the header) but only when the playlist is really missing from this device.
    private var ownerActions: some View {
        HStack(spacing: 10) {
            inviteButton
            overflowMenu
        }
    }

    private var inviteButton: some View {
        Button {
            showInvite = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Invite")
                    .font(.mixButtonSmall)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            #if os(iOS)
            .frame(maxWidth: .infinity)
            #endif
            .background(Color.mixAccentFill, in: Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help("Invite collaborators to \u{201C}\(summary.name)\u{201D}")
        .accessibilityLabel("Invite collaborators to \(summary.name)")
    }

    /// Everything that isn't the one thing. The code and the link are not here:
    /// they belong to the invite screen, which is the single place that shows
    /// what's currently being handed out and can change it.
    private var overflowMenu: some View {
        Menu {
            ShareMenuItems(.playlist(summary))
            Divider()
            Button {
                showInvite = true
            } label: {
                Label("Manage Collaborators", systemImage: "person.2")
            }

            if localCopyID != nil {
                Divider()
                Button {
                    Task { await hideFromProfile() }
                } label: {
                    Label("Hide from My Profile", systemImage: "eye.slash")
                }
                .disabled(isHiding)
            }

            // Only when the playlist genuinely isn't here. The published snapshot
            // is the only surviving record of what was in it, so this is a real
            // recovery path — it just isn't what you came to this page for.
            if libraryState == .missing, !summary.tracks.isEmpty {
                Divider()
                Button {
                    save()
                } label: {
                    Label("Restore to Library", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            HeroCircleLabel(systemImage: "ellipsis")
        }
        #if os(macOS)
        // Left alone a Menu draws itself as a bordered pop-up button, complete
        // with a chevron — the wrong shape entirely next to a capsule.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .frame(width: 40, height: 40)
        .help("More options for this playlist")
    }

    /// Sits under the header when the owner's own playlist isn't on this device.
    /// Same card as `unpublishedNote`, because it's the same kind of statement —
    /// something about this page's state that you'd otherwise have to infer.
    private var restoreNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Not in this library")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextSecondary)
                Text("You published this playlist, but it isn't on this device.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                save()
            } label: {
                Text("Restore")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.mixPrimary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.mixSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        )
    }

    // MARK: Visitor actions

    /// Two different things, and the difference is the point of this whole
    /// screen for a visitor.
    ///
    /// The button *saves*: the playlist joins your library and stays theirs — you
    /// can play it and download it, you can't edit it, and when they change it,
    /// your copy changes. The menu *copies*: you get your own playlist, editable,
    /// frozen at today, that never hears from them again. Spotify draws the same
    /// distinction and it's the one people actually reach for — most of the time
    /// you want the playlist, not a photograph of it.
    private var visitorActions: some View {
        HStack(spacing: 10) {
            addButton
            visitorMenu
        }
    }

    private var visitorMenu: some View {
        Menu {
            Button {
                makeCopy()
            } label: {
                Label("Make a Copy", systemImage: "doc.on.doc")
            }
            .disabled(summary.tracks.isEmpty)
            Divider()
            ShareMenuItems(.playlist(summary))

            if savedPlaylistID != nil {
                Divider()
                Button(role: .destructive) {
                    removeSaved()
                } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
            }
        } label: {
            HeroCircleLabel(systemImage: "ellipsis")
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .frame(width: 40, height: 40)
        .help("More options for this playlist")
    }

    /// This device's *saved* copy — the one that follows the owner — as opposed to
    /// a detached copy, which is an ordinary playlist and is removed like one.
    private var savedPlaylistID: UUID? {
        guard let id = localCopyID,
              deps.libraryService.playlist(id: id)?.followsRemoteSource == true
        else { return nil }
        return id
    }

    /// Wording matters more than usual here. "Add to Library" on your own playlist
    /// is a lie about what the button does — it would make a second one — so the
    /// owner's version says restore, and puts the playlist back where it was
    /// rather than beside itself.
    private var addButton: some View {
        let state = libraryState
        let isDone = state == .present

        return Button {
            save()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon(for: state))
                    .font(.system(size: 13, weight: .bold))
                    // The plus turning into a tick, rather than one label being
                    // swapped for another. It's the whole feedback the press
                    // gets now that there's no waiting to report.
                    .mixSymbolReplace()
                Text(title(for: state))
                    .font(.mixButtonSmall)
            }
            .foregroundStyle(isDone ? Color.mixTextSecondary : .white)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            #if os(iOS)
            .frame(maxWidth: .infinity)
            #endif
            .background(isDone ? Color.mixSurface : Color.mixPrimary, in: Capsule())
            .overlay {
                if isDone {
                    Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(isDone || summary.tracks.isEmpty)
        .mixAnimation(.snappy(duration: 0.2), value: isDone)
        .help(help(for: state))
    }

    private func icon(for state: LibraryState) -> String {
        switch state {
        case .present: return MixtapeIcons.checkmark
        case .missing: return "arrow.counterclockwise"
        case .absent:  return MixtapeIcons.add
        }
    }

    private func title(for state: LibraryState) -> String {
        switch state {
        case .present: return "In Your Library"
        case .missing: return "Restore to Library"
        case .absent:  return "Add to Library"
        }
    }

    private func help(for state: LibraryState) -> String {
        switch state {
        case .present: return "This playlist is already in your library"
        case .missing: return "Put this playlist back in your library"
        case .absent:  return "Save this playlist to your library. It stays @\(ownerName)'s, and updates when they change it."
        }
    }

    /// Rows published before the snapshot column existed carry a count and
    /// nothing else. Saying so beats an empty page that looks broken.
    private var unpublishedNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("No track list")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextSecondary)
                Text("@\(ownerName) hasn't published what's in this playlist.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.mixSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        )
    }

    // MARK: Actions

    /// The button. Restores the owner's own playlist, or saves someone else's —
    /// two genuinely different operations behind one control, because from the
    /// user's side it's the same sentence: put this in my library.
    ///
    /// Not `async`, and that's the fix: everything that has to happen before the
    /// playlist is in the library is local, so it all happens inside this call
    /// and the button is done by the time the press ends. The errands that used
    /// to be strung in front of it — a round trip to read the row, a cover GET,
    /// a full sync, then artwork for every song one at a time — now run behind
    /// it, where nobody is waiting.
    private func save() {
        let state = libraryState
        guard state != .present, !summary.tracks.isEmpty else { return }

        if state == .missing {
            restore()
        } else {
            subscribe()
        }
    }

    /// Saves someone else's public playlist: a real playlist in the library that
    /// goes on belonging to them.
    ///
    /// Everything that makes that true lives in `savePublicPlaylist` — the
    /// `.subscribed` origin that refuses edits, the viewer link that pulls and
    /// never pushes, and the absence of any server-side membership, which is what
    /// keeps a saver out of the collaborator byline.
    private func subscribe() {
        let localID = PlaylistSharingService.shared.savePublicPlaylist(
            sharedPlaylistID: summary.id,
            ownerID: summary.ownerID,
            ownerName: ownerName,
            name: summary.name,
            description: summary.description,
            artworkData: cover,
            trackMeta: sharedTrackMeta,
            libraryService: deps.libraryService
        )
        didAdd = true
        deps.showToast("Added \u{201C}\(summary.name)\u{201D} to your library")
        // Moved before the round trip so the header answers the press, not the
        // network. Only when a real count is already in hand: bumping nil to 1
        // would turn "the server hasn't told us" into "one person has this".
        if let known = saveCount { saveCount = known + 1 }

        // The server has the last word, it just doesn't get to hold the door.
        // This is what upgrades the songs the profile snapshot couldn't prove
        // were streamable, adopts the owner's own cover, and picks up anything
        // they changed between the page loading and the press.
        Task {
            await PlaylistSharingService.shared.recordSave(sharedPlaylistID: summary.id)
            await loadSaveCount()

            let status = await PlaylistSharingService.shared.refreshSubscription(
                localPlaylistID: localID,
                libraryService: deps.libraryService
            )
            switch status {
            case .available:
                try? await deps.syncService.sync()
            case .unavailable:
                // Privated in the seconds between this page loading and the
                // press. Rare enough to be worth undoing rather than explaining.
                rollBackSave(localID, reason: "@\(ownerName) has made this playlist private.")
            case .unknown:
                // Offline, or the server had a bad minute — deliberately not
                // undone. The same rule the rest of subscribing follows: a
                // device with no connection doesn't get to decide a playlist is
                // gone. What's here is a real snapshot, and opening it once
                // there's a connection refreshes it in place.
                break
            }
        }
    }

    /// Undoes a save the server then refused. Guarded on the playlist still being
    /// the one we saved: a user who reached the library and deleted it in the
    /// meantime has already said what they wanted.
    private func rollBackSave(_ localID: UUID, reason: String) {
        guard deps.libraryService.playlist(id: localID)?.origin == .subscribed else { return }
        PlaylistSharingService.shared.unsavePublicPlaylist(localPlaylistID: localID,
                                                           libraryService: deps.libraryService)
        didAdd = false
        actionError = reason
    }

    /// The owner's own playlist, back on a device that lost it.
    ///
    /// Reuses the published id so the existing shared row names this playlist
    /// again, and carries a fresh sync timestamp — which is what lets it win
    /// last-write-wins against whatever tombstone removed it. The published
    /// snapshot is the only surviving record of what was in there, so this
    /// reconciliation *is* the recovery.
    private func restore() {
        let library = deps.libraryService
        let local = library.createPlaylist(id: summary.playlistID,
                                           name: summary.name,
                                           description: summary.description,
                                           artworkData: cover,
                                           imported: true)
        // With the owner — themselves — so the reconciler's own artwork pass can
        // read the covers they published instead of guessing at the catalogue for
        // every song it just imported.
        library.reconcileSharedPlaylist(localPlaylistID: local.id,
                                        remoteTrackIDs: summary.tracks.map(\.id),
                                        remoteTrackMeta: sharedTrackMeta,
                                        ownerID: summary.ownerID)

        // Marked "owner" because the role is load-bearing and not just a label:
        // `setPublic` refuses to publish anything whose link says otherwise, and
        // creates a *second* shared row when there's no link at all. This way the
        // restored playlist's visibility toggle goes on driving the row it always
        // drove.
        PlaylistSharingService.shared.setLinkedShare(
            PlaylistSharingService.LinkedShare(sharedPlaylistID: summary.id,
                                               shareCode: "",
                                               role: PlaylistSharingService.Roles.owner),
            forLocalPlaylist: local.id
        )

        didAdd = true
        deps.showToast("Restored \u{201C}\(summary.name)\u{201D} to your library")

        // Both errands, and both behind the playlist rather than in front of it.
        // The empty code above leaves the playlist recognisable but not invitable,
        // and gives `refreshSharedPlaylist` nothing to look up; `inviteCode`
        // rewrites the link with the real one. Neither is anything the user is
        // waiting to see.
        Task {
            _ = try? await PlaylistSharingService.shared
                .inviteCode(forSharedPlaylist: summary.id, localPlaylistID: local.id)
            try? await deps.syncService.sync()
        }
    }

    /// Takes today's version and makes it yours.
    ///
    /// Deliberately linked to nothing. A copy is an ordinary playlist — rename
    /// it, reorder it, throw half of it out — and the owner's later edits never
    /// arrive, which is the entire difference from Save. Copying also doesn't
    /// count as saving: the button still offers to save afterwards, because you
    /// haven't.
    private func makeCopy() {
        guard !summary.tracks.isEmpty else { return }

        let library = deps.libraryService
        let local = library.createPlaylist(id: UUID(),
                                           name: summary.name,
                                           description: summary.description,
                                           artworkData: cover,
                                           imported: true)
        // A copy is an ordinary playlist and pushes nothing back, so songs the
        // user already owns are linked rather than duplicated into Songs.
        library.reconcileSharedPlaylist(localPlaylistID: local.id,
                                        remoteTrackIDs: summary.tracks.map(\.id),
                                        remoteTrackMeta: sharedTrackMeta,
                                        ownerID: summary.ownerID,
                                        dedupeAgainstLibrary: true)

        deps.showToast("Copied \u{201C}\(summary.name)\u{201D} to your library")
        Task { try? await deps.syncService.sync() }
    }

    /// Unsaves. The playlist leaves the library here and now; the counter row
    /// behind it is withdrawn in the background by `unsavePublicPlaylist`, and
    /// whether that succeeds has no bearing on the playlist being gone.
    private func removeSaved() {
        guard let id = savedPlaylistID else { return }
        PlaylistSharingService.shared.unsavePublicPlaylist(localPlaylistID: id,
                                                           libraryService: deps.libraryService)
        didAdd = false
        if let known = saveCount { saveCount = max(known - 1, 0) }
        deps.showToast("Removed \u{201C}\(summary.name)\u{201D} from your library")
    }

    /// The published snapshot in the shape the library's reconciler wants. Songs
    /// the viewer already owns get linked to their real files; the rest land as
    /// unavailable placeholders, so the playlist reads correctly now and fills in
    /// if those songs ever arrive.
    private var sharedTrackMeta: [PlaylistSharingService.SharedTrackMeta] {
        summary.tracks.map {
            PlaylistSharingService.SharedTrackMeta(id: $0.id,
                                                   title: $0.title,
                                                   artist: $0.artist,
                                                   album: $0.album,
                                                   duration: $0.duration)
        }
    }

    /// Fetches covers for the local copies of these songs.
    ///
    /// Also runs for a playlist that's *already* in the library, which is the
    /// only repair path for a copy adopted before covers were published — those
    /// tracks are sitting in the library blank and nothing else will ever revisit
    /// them. Placeholders keep the owner's track ids, so the same lookup works on
    /// a copy that was made months ago. Costs nothing when they all have covers.
    private func fillInCovers() async {
        await deps.libraryService.backfillPlaceholderArtwork(
            trackIDs: summary.tracks.map(\.id),
            publishedBy: summary.ownerID,
            using: deps.itunesClient
        )
    }

    /// Takes the playlist off the profile. Needs the local copy — `setPublic`
    /// republishes the track snapshot on its way through, so it works from the
    /// playlist rather than from the row.
    private func hideFromProfile() async {
        guard let localID = localCopyID,
              let playlist = deps.libraryService.playlist(id: localID)
        else { return }

        isHiding = true
        defer { isHiding = false }

        do {
            try await PlaylistSharingService.shared.setPublic(
                false,
                playlist: playlist,
                tracks: playlist.trackIDs.compactMap { deps.libraryService.track(id: $0) },
                deviceID: AppDependencies.deviceID
            )
            deps.showToast("Hidden from your profile")
        } catch {
            actionError = "Couldn't hide this playlist from your profile."
        }
    }

    /// The owner is filtered out rather than assumed absent. They have no
    /// collaborator row when they publish, but `refreshSharedPlaylist` goes
    /// through the same join RPC as everyone else, so opening your own shared
    /// playlist once is enough to enrol you in it — and "1 collaborator" on a
    /// playlist nobody has joined is a lie you'd never think to check.
    private func loadCollaborators() async {
        guard isMine else { return }
        let rows = (try? await PlaylistSharingService.shared
            .collaborators(sharedPlaylistID: summary.id)) ?? []
        collaboratorCount = rows.filter { $0.userID != summary.ownerID }.count
    }

    private func load() async {
        await artwork.resolveCovers([summary],
                                    library: deps.libraryService,
                                    catalogue: deps.itunesClient)
        switch artwork.playlistCovers[summary.id] {
        case .data(let data):
            cover = data
        case .remote(let url):
            cover = try? await URLSession.shared.data(from: url).0
        case nil:
            break
        }

        await loadCollaborators()
        await loadSaveCount()

        if libraryState == .present { await fillInCovers() }
    }

    private func loadSaveCount() async {
        saveCount = await PlaylistSharingService.shared.saveCount(sharedPlaylistID: summary.id)
    }

    private enum Metrics {
        #if os(macOS)
        static let inset: CGFloat = 24
        #else
        static let inset: CGFloat = 16
        #endif
    }
}

// MARK: - Columns

/// Chosen by measured width rather than by platform, matching the library's own
/// playlist table so a Mac window dragged narrow degrades the same way.
private struct PublicTrackColumns {

    var showsAlbum = false
    var albumWidth: CGFloat = 0

    var isTable: Bool { showsAlbum }

    /// Four digits — a shared playlist is as long as its owner made it.
    static let index:    CGFloat = 32
    static let duration: CGFloat = 44
    /// Artwork (40) plus the gap before the title — how far the header's "Title"
    /// has to be pushed to sit over the song titles.
    static let titleInset: CGFloat = 52

    init(width: CGFloat) {
        showsAlbum = width >= 640
        albumWidth = showsAlbum ? min(max(width * 0.24, 130), 280) : 0
    }
}

private struct PublicTrackListHeader: View {

    let columns: PublicTrackColumns

    var body: some View {
        HStack(spacing: 10) {
            Text("#")
                .frame(width: PublicTrackColumns.index, alignment: .trailing)

            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, PublicTrackColumns.titleInset)

            if columns.showsAlbum {
                Text("Album")
                    .frame(width: columns.albumWidth, alignment: .leading)
            }

            Image(systemName: "clock")
                .frame(width: PublicTrackColumns.duration, alignment: .trailing)
        }
        .font(.mixCaption)
        .foregroundStyle(Color.mixTextTertiary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.mixSeparator).frame(height: 0.5)
        }
    }
}

// MARK: - Row

/// One published song. Inert on purpose — there is nothing behind it to play, so
/// it gets no hover pill and no selection either; a row that lights up under the
/// cursor is promising a click that does something.
private struct PublicTrackRow: View {

    let track: PublicPlaylistTrack
    let index: Int
    let columns: PublicTrackColumns
    /// The viewer's own copy of this song, when they happen to have one. Usually
    /// nil on someone else's playlist.
    let artwork: Data?
    /// The owner's cover, published with the playlist. What fills the row in the
    /// usual case, where the viewer owns none of these songs.
    let remoteArtwork: URL?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.mixCaption.monospacedDigit())
                .foregroundStyle(Color.mixTextTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: PublicTrackColumns.index, alignment: .trailing)

            ArtworkThumbnail(data: artwork,
                             size: 40,
                             cornerRadius: 4,
                             placeholder: MixtapeIcons.track,
                             remoteURL: remoteArtwork)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if columns.showsAlbum {
                Text(track.album.isEmpty ? "—" : track.album)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                    .frame(width: columns.albumWidth, alignment: .leading)
            }

            Text(durationLabel)
                .font(.mixCaption.monospacedDigit())
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: PublicTrackColumns.duration, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var durationLabel: String {
        guard track.duration > 0 else { return "—" }
        let total = Int(track.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
