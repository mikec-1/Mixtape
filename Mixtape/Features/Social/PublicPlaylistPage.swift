// Someone else's public playlist, read-only. Same shape as PlaylistDetailView (DetailHero
// and the column table) minus play, edit, delete and visibility: a visitor has none of the
// files, so all they can do is add it to their library.
// A separate view because PlaylistDetailView is wired to a local Playlist throughout.

import Foundation
import SwiftUI

// MARK: - Navigation target

/// A public playlist plus its owner, whose handle the summary doesn't carry.
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

    /// The cover as bytes: the wash and the library copy both need data, not a URL.
    @State private var cover: Data?
    /// Set once the playlist is in the library. Saving is local, so there's no in-progress state.
    @State private var didAdd = false
    /// Measured so the table drops columns it can't fit, like the library's table.
    @State private var listWidth: CGFloat = 0

    @State private var showInvite = false
    /// Only loaded for our own playlist; visitors get nothing from the collaborator policies.
    @State private var collaboratorCount = 0
    /// Nil while unknown (or without `get_playlist_save_count`), so the header never claims zero.
    @State private var saveCount: Int?
    @State private var notes: PlaylistNotes?
    @State private var isHiding = false
    @State private var actionError: String?

    public init(summary: PublicPlaylistSummary, ownerName: String) {
        self.summary = summary
        self.ownerName = ownerName
    }

    private var columns: PublicTrackColumns { PublicTrackColumns(width: listWidth) }

    /// What the single button on this page is for.
    private enum LibraryState {
        /// Here already: your own row, or a copy you adopted earlier.
        case present
        /// Yours, still published, and not in this library. See `save()`.
        case missing
        /// Somebody else's, and you don't have it.
        case absent
    }

    /// Whether the viewer published this. Decided by the row's owner, not by whether this
    /// device has the playlist.
    private var isMine: Bool {
        guard let ownerID = summary.ownerID,
              let viewer = deps.authService.currentUser?.id
        else { return false }
        return ownerID == viewer
    }

    /// `summary.playlistID` is the owner's local id, so it only matches on your own profile.
    /// An adopted copy has a fresh id and is found through its stored link.
    private var libraryState: LibraryState {
        if didAdd || localCopyID != nil { return .present }
        return isMine ? .missing : .absent
    }

    /// This device's copy under either id. Nil is the only case that offers Restore.
    private var localCopyID: UUID? {
        if deps.libraryService.playlist(id: summary.playlistID) != nil { return summary.playlistID }
        // The link can outlive the playlist, so check it still exists.
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

                // Secondary on your own profile: sharing is the main action here.
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

                if let notes, !notes.isEmpty {
                    LinerNotesView(notes: notes, songs: summary.tracks.map { ($0.id, $0.title) })
                        .padding(.horizontal, Metrics.inset)
                        .padding(.top, 28)
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
        .background(MixPageBackground())
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
            eyebrow: summary.isDub ? "Dub from @\(ownerName)" : "Public Playlist",
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

    /// Owner first: it's what distinguishes this from your own library page.
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

    /// The owner's primary action: invite. Restore is in the overflow, only when missing.
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

    /// Everything else. Codes and links live on the invite screen.
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

            // Only when missing here. The snapshot is the only record of what was in it.
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
        // Otherwise a Menu draws as a bordered pop-up with a chevron.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .frame(width: 40, height: 40)
        .help("More options for this playlist")
    }

    /// Under the header when the owner's playlist isn't on this device. Same card as `unpublishedNote`.
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

    /// The button saves: it joins your library, stays theirs, and follows their edits.
    /// The menu copies: your own editable playlist, frozen at today.
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

    /// This device's saved copy (follows the owner), not a detached copy.
    private var savedPlaylistID: UUID? {
        guard let id = localCopyID,
              deps.libraryService.playlist(id: id)?.followsRemoteSource == true
        else { return nil }
        return id
    }

    /// The owner's version says Restore and puts the playlist back, rather than adding a second one.
    private var addButton: some View {
        let state = libraryState
        let isDone = state == .present

        return Button {
            save()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon(for: state))
                    .font(.system(size: 13, weight: .bold))
                    // Plus turns into a tick.
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

    /// Rows published before the snapshot column carry only a count.
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

    /// Restores the owner's playlist or saves someone else's. Synchronous: everything
    /// before the playlist lands is local, and the network errands run behind it.
    private func save() {
        let state = libraryState
        guard state != .present, !summary.tracks.isEmpty else { return }

        if state == .missing {
            restore()
        } else {
            subscribe()
        }
    }

    /// Saves someone else's playlist, still theirs. `savePublicPlaylist` sets the `.subscribed`
    /// origin, the pull-only link, and no server membership (so no collaborator byline).
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
        deps.showToast(Toast.done("Added \u{201C}\(summary.name)\u{201D} to your library")
            .action("View") { Toast.openPlaylist(localID) })
        // Bump before the round trip, but only a known count: nil must not become 1.
        if let known = saveCount { saveCount = known + 1 }

        // Server refresh in the background: upgrades streamable songs, adopts the owner's cover,
        // picks up any recent edits.
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
                // Made private since the page loaded.
                rollBackSave(localID, reason: "@\(ownerName) has made this playlist private.")
            case .unknown:
                // Offline or a server error: keep the save. Opening it later refreshes it.
                break
            }
        }
    }

    /// Undoes a save the server refused, unless the user already deleted it.
    private func rollBackSave(_ localID: UUID, reason: String) {
        guard deps.libraryService.playlist(id: localID)?.origin == .subscribed else { return }
        PlaylistSharingService.shared.unsavePublicPlaylist(localPlaylistID: localID,
                                                           libraryService: deps.libraryService)
        didAdd = false
        actionError = reason
    }

    /// The owner's own playlist, back on a device that lost it. Reuses the published id and a
    /// fresh sync timestamp so it wins last-write-wins against the tombstone.
    private func restore() {
        let library = deps.libraryService
        let local = library.createPlaylist(id: summary.playlistID,
                                           name: summary.name,
                                           description: summary.description,
                                           artworkData: cover,
                                           imported: true)
        // With the owner as themselves, so the artwork pass uses their published covers.
        library.reconcileSharedPlaylist(localPlaylistID: local.id,
                                        remoteTrackIDs: summary.tracks.map(\.id),
                                        remoteTrackMeta: sharedTrackMeta,
                                        ownerID: summary.ownerID,
                                        notes: notes)

        // "owner" matters: `setPublic` refuses to publish otherwise, and with no link it creates a second row.
        PlaylistSharingService.shared.setLinkedShare(
            PlaylistSharingService.LinkedShare(sharedPlaylistID: summary.id,
                                               shareCode: "",
                                               role: PlaylistSharingService.Roles.owner),
            forLocalPlaylist: local.id
        )

        didAdd = true
        deps.showToast(.done("Restored \u{201C}\(summary.name)\u{201D} to your library"))

        // In the background: `inviteCode` replaces the empty code above with the real one.
        Task {
            _ = try? await PlaylistSharingService.shared
                .inviteCode(forSharedPlaylist: summary.id, localPlaylistID: local.id)
            try? await deps.syncService.sync()
        }
    }

    /// Today's version as your own playlist, linked to nothing. Doesn't count as saving.
    private func makeCopy() {
        guard !summary.tracks.isEmpty else { return }

        let library = deps.libraryService
        let local = library.createPlaylist(id: UUID(),
                                           name: summary.name,
                                           description: summary.description,
                                           artworkData: cover,
                                           imported: true)
        // Songs the user already owns are linked rather than duplicated.
        library.reconcileSharedPlaylist(localPlaylistID: local.id,
                                        remoteTrackIDs: summary.tracks.map(\.id),
                                        remoteTrackMeta: sharedTrackMeta,
                                        ownerID: summary.ownerID,
                                        dedupeAgainstLibrary: true,
                                        notes: notes)

        deps.showToast(Toast.done("Copied \u{201C}\(summary.name)\u{201D} to your library")
            .action("View") { Toast.openPlaylist(local.id) })
        Task { try? await deps.syncService.sync() }
    }

    /// Unsaves locally now; `unsavePublicPlaylist` withdraws the counter row in the background.
    private func removeSaved() {
        guard let id = savedPlaylistID else { return }
        PlaylistSharingService.shared.unsavePublicPlaylist(localPlaylistID: id,
                                                           libraryService: deps.libraryService)
        didAdd = false
        if let known = saveCount { saveCount = max(known - 1, 0) }
        deps.showToast(Toast.done("Removed \u{201C}\(summary.name)\u{201D} from your library")
            .action("Undo") { subscribe() })
    }

    /// The snapshot as reconciler input. Owned songs link to real files, the rest become placeholders.
    private var sharedTrackMeta: [PlaylistSharingService.SharedTrackMeta] {
        summary.tracks.map {
            var meta = PlaylistSharingService.SharedTrackMeta(id: $0.id,
                                                              title: $0.title,
                                                              artist: $0.artist,
                                                              album: $0.album,
                                                              duration: $0.duration,
                                                              sourceKey: $0.sourceKey)
            meta.edit = $0.edit
            return meta
        }
    }

    /// Fetches covers for the local copies of these songs. Also repairs copies adopted
    /// before covers were published; placeholders keep the owner's ids.
    private func fillInCovers() async {
        await deps.libraryService.backfillPlaceholderArtwork(
            trackIDs: summary.tracks.map(\.id),
            publishedBy: summary.ownerID,
            using: deps.itunesClient
        )
    }

    /// Takes it off the profile. Needs the local copy, since `setPublic` republishes the snapshot.
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
            deps.showToast(.done("Hidden from your profile"))
        } catch {
            actionError = "Couldn't hide this playlist from your profile."
        }
    }

    /// Filters out the owner: opening your own shared playlist enrols you through the join RPC.
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

        notes = try? await PlaylistSharingService.shared.fetchPublicPlaylist(sharedPlaylistID: summary.id).notes
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

/// By measured width, not platform, like the library's playlist table.
private struct PublicTrackColumns {

    var showsAlbum = false
    var albumWidth: CGFloat = 0

    var isTable: Bool { showsAlbum }

    /// Room for four digits.
    static let index:    CGFloat = 32
    static let duration: CGFloat = 44
    /// Artwork (40) plus the gap, so the "Title" header sits over the titles.
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

/// One published song. Inert: nothing to play, so no hover or selection.
private struct PublicTrackRow: View {

    let track: PublicPlaylistTrack
    let index: Int
    let columns: PublicTrackColumns
    /// The viewer's own copy's artwork, if any.
    let artwork: Data?
    /// The owner's published cover, the usual fill.
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
