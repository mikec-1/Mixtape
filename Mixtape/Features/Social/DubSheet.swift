// Dub a playlist for someone: a copy with a cover and a note, sent as a link.
// The page it opens says who made it and who it's for, and the copy never changes.

import SwiftUI

struct DubSheet: View {
    let playlist: Playlist
    let tracks: [Track]

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var recipient = ""
    @State private var note = ""
    @State private var artworkData: Data?
    @State private var isMaking = false

    private var name: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                    TextField("Write them a note", text: $note, axis: .vertical)
                        .lineLimit(4...8)
                        .mixSheetField()
                }
            }
        }
        .task { artworkData = playlist.displayArtwork }
        // The server's limits (20260926040000).
        .onChange(of: recipient) { _, v in if v.count > 80 { recipient = String(v.prefix(80)) } }
        .onChange(of: note) { _, v in if v.count > 2000 { note = String(v.prefix(2000)) } }
    }

    private func make() {
        guard !isMaking else { return }
        isMaking = true
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await PlaylistSharingService.shared.dub(
                    playlist: playlist, tracks: tracks, artworkData: artworkData,
                    for: name, note: text.isEmpty ? nil : text)
                let item = ShareItem.dub(playlist, sharedID: id, for: name, artwork: artworkData)
                copyToClipboard(item.url.absoluteString)
                deps.showToast("Dub for \(name) made. Link copied")
                dismiss()
                #if os(iOS)
                ShareSheet.present(item, deps: deps)
                #endif
            } catch {
                isMaking = false
                deps.showToast("Couldn\u{2019}t make the dub. Try again.")
            }
        }
    }
}
