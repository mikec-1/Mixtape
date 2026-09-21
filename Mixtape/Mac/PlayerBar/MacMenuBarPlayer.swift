#if os(macOS)
import SwiftUI

/// The menu bar mini-player: the song and the three transport buttons, for
/// when the window is buried. Switched off in Settings ▸ General.
struct MacMenuBarPlayer: View {
    static let visibleKey = "mac.menuBarPlayer"

    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var queue: QueueService

    var body: some View {
        let track = queue.currentTrack
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                MacArtworkView(data: track?.artworkData, artworkRef: track.map { .track($0.id) },
                               size: 48, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.displayTitle ?? "Not Playing").font(.headline)
                    if let track { Text(track.displayArtistName).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 28) {
                Button { Task { await engine.playPrevious() } } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous")
                    .disabled(track == nil)
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.state.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")
                Button { Task { await engine.playNext() } } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next")
                    .disabled(track == nil)
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260)
    }
}
#endif
