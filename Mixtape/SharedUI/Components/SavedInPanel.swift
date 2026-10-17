// "Where is this song saved?" as a small panel above the player bar, not a
// modal. Bottom-leading, next to the + that opens it. No dimming; an invisible
// catcher closes it on the next click elsewhere. iOS keeps a sheet.

import SwiftUI
import Combine

// MARK: - Center

/// The one open panel. Separate from `AppDependencies` so opening it doesn't
/// redraw the whole tree (like `savedToasts`).
@MainActor
public final class SavedInPanelCenter: ObservableObject {

    public struct Request: Identifiable, Equatable {
        public let id = UUID()
        public var tracks: [Track]
        /// Whether the panel leads with "where is this" or "file this".
        public var isSavedIn: Bool
        /// The playlist the panel was opened from, which it won't offer.
        public var sourcePlaylistID: UUID?

        public static func == (a: Request, b: Request) -> Bool { a.id == b.id }
    }

    @Published public private(set) var request: Request?

    public init() {}

    public func show(tracks: [Track], isSavedIn: Bool, sourcePlaylistID: UUID? = nil) {
        guard !tracks.isEmpty else { return }
        request = Request(tracks: tracks,
                          isSavedIn: isSavedIn,
                          sourcePlaylistID: sourcePlaylistID)
    }

    public func dismiss() { request = nil }
}

// MARK: - Host

#if os(macOS)
/// Places the panel bottom-leading above the player bar. Fixed size so it
/// doesn't jump while searching.
public struct SavedInPanelHost: View {

    @ObservedObject private var center: SavedInPanelCenter
    /// Room left under the panel for the player bar.
    private let bottomGap: CGFloat

    public init(center: SavedInPanelCenter, bottomGap: CGFloat = 0) {
        self.center = center
        self.bottomGap = bottomGap
    }

    /// Cover, name and mark, no wider.
    public static let width: CGFloat  = 300
    public static let height: CGFloat = 460

    /// Matches the player bar's inset so the panel lines up with it.
    public static let leadingInset: CGFloat = 20

    /// Gap to anything stacked above (the downloading card).
    public static let stackGap: CGFloat = 10

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let request = center.request {
                // Click catcher. Clear, not dark.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { center.dismiss() }

                AddToPlaylistSheet(tracks: request.tracks,
                                   purpose: request.isSavedIn ? .savedIn : .add,
                                   sourcePlaylistID: request.sourcePlaylistID,
                                   chrome: .panel,
                                   onClose: { center.dismiss() })
                    .frame(width: Self.width, height: Self.height)
                    .padding(.leading, Self.leadingInset)
                    .padding(.bottom, bottomGap)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Esc, like every other dismissible overlay in the app.
                    .onExitCommand { center.dismiss() }
            }
        }
        .mixAnimation(.mixSoft, value: center.request)
    }
}
#endif
