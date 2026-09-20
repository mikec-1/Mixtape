// SavedInPanel.swift
// Mixtape — SharedUI/Components
//
// "Where is this song saved?", as a panel rather than a sheet.
//
// This started life as a modal sheet, and on the Mac that was the wrong shape
// twice over: a 580×680 window landed over the app for a question you answer in
// two seconds, and everything behind it went dark and unusable while you did.
// The answer is a small box just above the now-playing bar, with the rest of the
// app still lit and still running. That is what this is.
//
// Bottom-*leading*, not trailing: the panel is opened from the + beside the song
// in the player bar, and a box that appears in the opposite corner from the
// thing you clicked reads as an unrelated window. It rises directly out of the
// control that summoned it instead.
//
// Nothing here dims. The only thing between the panel and the app is an
// invisible catcher that turns the next click anywhere else into "close" —
// which is the gesture people already expect from a popover, and the reason a
// scrim isn't needed to communicate modality: it isn't modal.
//
// iOS keeps the sheet. A phone has no corner to spare and a sheet *is* the
// native answer there; the port that needed fixing was the Mac one.

import SwiftUI
import Combine

// MARK: - Center

/// Holds the one panel that can be open at a time.
///
/// A separate observable rather than another `@Published` on `AppDependencies`,
/// for the same reason `savedToasts` is: every view in the app observes `deps`,
/// and opening a small corner panel has no business redrawing the whole tree.
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
/// Drops the panel into the bottom-leading corner of the window, above the
/// player bar. Sized here rather than by the content: the panel has to be the
/// same box whether it lists two playlists or forty, or it would jump about as
/// you type in its search field.
public struct SavedInPanelHost: View {

    @ObservedObject private var center: SavedInPanelCenter
    /// Room to leave under the panel for the player bar. Whatever is stacked
    /// above the panel measures from the same baseline.
    private let bottomGap: CGFloat

    public init(center: SavedInPanelCenter, bottomGap: CGFloat = 0) {
        self.center = center
        self.bottomGap = bottomGap
    }

    /// Wide enough for a 44pt cover, a name and a mark, and no wider: the extra
    /// 80pt this used to carry was empty track between the playlist's name and
    /// its mark, which pushed the column of marks away from the names they
    /// belong to and made the box read as a window rather than a menu.
    public static let width: CGFloat  = 300
    public static let height: CGFloat = 460

    /// Left inset, matching the player bar's own content inset, so the panel's
    /// edge lines up with the artwork, title and + button underneath it.
    public static let leadingInset: CGFloat = 20

    /// Room left between this panel and anything stacked on top of it — the
    /// downloading card, which shares this corner.
    public static let stackGap: CGFloat = 10

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let request = center.request {
                // The catcher. Clear, not dark — the app stays lit, it just
                // stops taking the click that closes this.
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
        .mixAnimation(.spring(response: 0.32, dampingFraction: 0.88), value: center.request)
    }
}
#endif
