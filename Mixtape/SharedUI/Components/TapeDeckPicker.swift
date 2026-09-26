import SwiftUI

/// The queue's tape decks. Tapping one parks this queue and picks that one up where it stopped.
struct TapeDeckPicker: View {
    @ObservedObject var decks: TapeDeckService
    /// Observed so "Save as Playlist" hides on an empty queue.
    @EnvironmentObject private var queueService: QueueService

    @State private var isRenaming = false
    @State private var isSaving   = false
    @State private var draft      = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(decks.decks) { deck in
                let isOn = deck.id == decks.activeID
                Button {
                    Haptics.play(.selection)
                    Task { await decks.switchTo(deck.id) }
                } label: {
                    Text(deck.name)
                        .font(.mixButtonSmall)
                        .lineLimit(1)
                        .foregroundStyle(isOn ? Color.mixOnAccent : Color.mixTextPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isOn ? Color.mixAccentFill : Color.mixSurface2, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .help(isOn ? "Playing from this deck" : "Switch to \(deck.name)")
            }

            Spacer(minLength: 4)

            Menu {
                Button("Rename Deck\u{2026}") {
                    draft = decks.activeName
                    isRenaming = true
                }
                if !queueService.queue.isEmpty {
                    Button("Save as Playlist\u{2026}") {
                        draft = queueService.source.displayName ?? decks.activeName
                        isSaving = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .accessibilityLabel("Deck options")
        }
        .alert("Rename Deck", isPresented: $isRenaming) {
            TextField("Name", text: $draft)
            Button("Rename") { decks.rename(decks.activeID, to: draft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save as Playlist", isPresented: $isSaving) {
            TextField("Playlist name", text: $draft)
            Button("Save") { Task { await decks.saveAsPlaylist(named: draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every song in this deck's queue, in order.")
        }
    }
}
