// Floating mini-player: a small always-on-top window with the song and transport.
// Toggled from Controls > Mini Player or ⌃⌥⌘M from any app.

#if os(macOS)
import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class MacMiniPlayer {

    static let shared = MacMiniPlayer()

    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let engine = MacDockMenu.engine else { return }
        let panel = panel ?? makePanel(engine: engine)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// ⌃⌥⌘M, global. A Carbon hot key needs no Accessibility permission.
    func registerHotKey() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { MacMiniPlayer.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        // Fails quietly if another app holds the combination; the menu item still works.
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey),
                            EventHotKeyID(signature: 0x4D58_4D50, id: 1),   // "MXMP"
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// The window follows the view's size; keep its top edge where it was.
    func refit() {
        guard let panel else { return }
        let top = panel.frame.maxY
        DispatchQueue.main.async {
            guard let size = panel.contentView?.fittingSize else { return }
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height,
                                  width: size.width, height: size.height), display: true)
            panel.invalidateShadow()
        }
    }

    private func makePanel(engine: PlaybackEngine) -> NSPanel {
        // Borderless: no title bar strip over the content. The view draws its own corners.
        let panel = MiniPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Always over a dark cover, so the slider and labels draw for dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MacMiniPlayerView(engine: engine, queue: engine.queue))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        // First open: top right of the screen. After that, wherever it was left.
        if !panel.setFrameUsingName("MiniPlayer"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName("MiniPlayer")
        return panel
    }

    /// Takes clicks without bringing Mixtape forward.
    private final class MiniPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

struct MacMiniPlayerView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var queue: QueueService

    /// Big artwork on top, or one compact row.
    @AppStorage("miniPlayerLarge") private var large = false
    @State private var hovering = false

    private static let corner: CGFloat = 14

    var body: some View {
        let track = queue.currentTrack
        Group {
            if large {
                VStack(spacing: 12) {
                    artwork(track, size: 272)
                    titles(track)
                    scrubber
                    transport(hasTrack: track != nil)
                }
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        artwork(track, size: 64)
                        titles(track)
                        Spacer(minLength: 0)
                        transport(hasTrack: track != nil)
                    }
                    scrubber
                }
            }
        }
        .padding(14)
        .frame(width: large ? 300 : 360)
        .background { backdrop(track) }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .overlay(alignment: .top) {
            if hovering {
                HStack {
                    chromeButton(large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 help: large ? "Smaller" : "Bigger Artwork") { large.toggle() }
                    Spacer()
                    chromeButton("xmark", help: "Close Mini Player") { MacMiniPlayer.shared.toggle() }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .mixAnimation(.mixQuick, value: hovering)
        .onChange(of: large) { MacMiniPlayer.shared.refit() }
    }

    private func artwork(_ track: Track?, size: CGFloat) -> some View {
        MacArtworkView(data: track?.artworkData, artworkRef: track.map { .track($0.id) },
                       size: size, cornerRadius: size > 100 ? 10 : 6)
            .mixShadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private func titles(_ track: Track?) -> some View {
        VStack(alignment: large ? .center : .leading, spacing: 2) {
            Text(track?.displayTitle ?? "Not Playing")
                .font(.system(size: large ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
            if let track {
                Text(track.displayArtistName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: large ? .infinity : nil)
    }

    private var scrubber: some View {
        MacProgressScrubber(clock: engine.clock)
            .environmentObject(engine)
    }

    /// The cover itself, blurred and darkened, behind everything.
    private func backdrop(_ track: Track?) -> some View {
        ZStack {
            Color(white: 0.12)
            if let track {
                MacArtworkView(data: track.artworkData, artworkRef: .track(track.id), size: nil, cornerRadius: 0)
                    .blur(radius: 40, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(0.35)
            }
        }
    }

    private func chromeButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func transport(hasTrack: Bool) -> some View {
        HStack(spacing: large ? 28 : 14) {
            Button { Task { await engine.playPrevious() } } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
                .disabled(!hasTrack)
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: large ? 42 : 30))
            }
            .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")
            Button { Task { await engine.playNext() } } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
                .disabled(!hasTrack)
        }
        .font(.system(size: large ? 18 : 15))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }
}

/// On the player bar's cover: an arrow on hover that pops the song out into the mini-player.
struct MiniPlayerCoverButton: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { MacMiniPlayer.shared.toggle() } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .padding(3)
                    .help("Mini Player")
                    .accessibilityLabel("Mini Player")
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .mixAnimation(.mixQuick, value: hovering)
    }
}
#endif
