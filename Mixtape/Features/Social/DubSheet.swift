// Dub a playlist for someone: a copy with a cover and a note, sent as a link.
// The page it opens says who made it and who it's for, and the copy never changes.
// Picking a Mixtape user from the suggestions also puts it in their inbox.

import SwiftUI

struct DubSheet: View {
    let playlist: Playlist
    let tracks: [Track]

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @StateObject private var people = PeopleSearch()
    @State private var recipient: String
    @State private var sendTo: UserProfile?
    @State private var note = ""
    @State private var artworkData: Data?
    @State private var isMaking = false

    private var name: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(playlist: Playlist, tracks: [Track], recipient: String = "") {
        self.playlist = playlist
        self.tracks = tracks
        _recipient = State(initialValue: recipient)
    }

    var body: some View {
        MixSheet(title: "Dub for Someone",
                 subtitle: "A copy of \u{201C}\(playlist.name)\u{201D} made for one person. Later changes to the playlist won\u{2019}t reach it.",
                 size: .medium,
                 primary: MixSheetAction("Make Dub",
                                         isEnabled: !name.isEmpty && !tracks.isEmpty,
                                         isBusy: isMaking,
                                         action: make)) {
            HStack(alignment: .top, spacing: 16) {
                ArtworkPickerView<AnyView>.standard(data: $artworkData, size: 120)
                VStack(spacing: 10) {
                    TextField("Who\u{2019}s it for?", text: $recipient)
                        .mixSheetField()
                    if let sendTo {
                        sendingTo(sendTo)
                    } else {
                        ForEach(people.results) { profile in
                            Button { pick(profile) } label: {
                                PersonResultRow(profile: profile, showsChevron: false)
                            }
                            .buttonStyle(.plain)
                            .mixHandCursor()
                        }
                    }
                    TextField("Write them a note", text: $note, axis: .vertical)
                        .lineLimit(4...8)
                        .mixSheetField()
                }
            }
        }
        .task { artworkData = playlist.displayArtwork }
        .task(id: recipient) {
            guard sendTo == nil else { return }
            await people.search(recipient, using: deps.authService, limit: 3)
        }
        // The server's limits (20260926040000).
        .onChange(of: recipient) { _, v in
            if v.count > 80 { recipient = String(v.prefix(80)) }
            // Typing over a picked name makes it a plain dedication again.
            if let sendTo, v != sendTo.name { self.sendTo = nil }
        }
        .onChange(of: note) { _, v in if v.count > 2000 { note = String(v.prefix(2000)) } }
    }

    private func sendingTo(_ profile: UserProfile) -> some View {
        HStack(spacing: 8) {
            AvatarView(url: profile.avatarURL, seed: profile.username, size: 20)
            Text("Goes to @\(profile.username)\u{2019}s inbox")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { sendTo = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .buttonStyle(.plain)
            .mixHandCursor()
            .accessibilityLabel("Don\u{2019}t send to their inbox")
        }
        .padding(.horizontal, 4)
    }

    private func pick(_ profile: UserProfile) {
        sendTo = profile
        recipient = profile.name
        people.clear()
    }

    private func make() {
        guard !isMaking else { return }
        isMaking = true
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = sendTo
        Task {
            do {
                let id = try await PlaylistSharingService.shared.dub(
                    playlist: playlist, tracks: tracks, artworkData: artworkData,
                    for: name, to: to?.id, note: text.isEmpty ? nil : text)
                let item = ShareItem.dub(playlist, sharedID: id, for: name, artwork: artworkData)
                copyToClipboard(item.url.absoluteString)
                deps.showToast(.done(to == nil ? "Dub for \(name) made. Link copied"
                                               : "Dub sent to \(name). Link copied"))
                dismiss()
                #if os(iOS)
                // A sent dub is already in their inbox.
                if to == nil { ShareSheet.present(item, deps: deps) }
                #endif
            } catch {
                isMaking = false
                deps.showToast(.failed("Couldn\u{2019}t make the dub. Try again.", error))
            }
        }
    }
}
