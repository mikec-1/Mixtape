// The save control's pop, and the pill saying where the song went. The pill
// uses the destination's cover via `PlaylistArtwork`, same as the sidebar.

import SwiftUI
import Combine

// MARK: - Destination

/// Where a song landed. All playlists underneath (Favourites and the library are
/// system rows). The name is carried so a deleted playlist still reads right.
public enum SaveDestination: Equatable, Hashable {
    case library
    case favourites
    /// Favouriting an unsaved song saves it too: one card, not two.
    case libraryAndFavourites
    case playlist(id: UUID, name: String)

    /// The row to draw the cover from.
    var playlistID: UUID {
        switch self {
        case .library:          Playlist.allSongsID
        // The favourites cover, the more specific of the two.
        case .favourites, .libraryAndFavourites: Playlist.favouritesID
        case .playlist(let id, _): id
        }
    }

    var name: String {
        switch self {
        case .library:             "Library"
        case .favourites:          "Liked Songs"
        case .libraryAndFavourites: "Library and Liked Songs"
        case .playlist(_, let name): name
        }
    }

    /// Drawn only when the playlist itself has gone missing.
    var fallbackIcon: String {
        switch self {
        case .library:    "music.note.list"
        case .favourites, .libraryAndFavourites: "heart.fill"
        case .playlist:   MixtapeIcons.playlist
        }
    }
}

// MARK: - Toast model

/// Has an id so saving twice to the same place shows the pill again.
public struct SavedToast: Identifiable, Equatable {

    public static func == (a: SavedToast, b: SavedToast) -> Bool { a.id == b.id }

    /// Which way the song moved. Both directions share the same pill, cover and timing.
    public enum Direction { case added, removed }

    public let id = UUID()
    public let destination: SaveDestination
    /// How many songs went in. Only ever > 1 from a multi-select add.
    public let count: Int
    public let direction: Direction
    /// View for adds, Undo for removes.
    public let action: Toast.Action?

    public init(destination: SaveDestination, count: Int = 1,
                direction: Direction = .added, action: Toast.Action? = nil) {
        self.destination = destination
        self.count = count
        self.direction = direction
        self.action = action
    }

    /// Count only for more than one song.
    var text: String {
        let verb = direction == .added ? "Added to" : "Removed from"
        return count == 1 ? "\(verb) \(destination.name)"
                          : "\(count) songs \(verb.lowercased()) \(destination.name)"
    }
}

// MARK: - Presenter

/// Owns the current pill. Separate from `deps` so showing it doesn't invalidate
/// the whole view tree. Held as a plain `let`.
@MainActor
public final class SavedToastCenter: ObservableObject {

    @Published public private(set) var current: SavedToast? = nil

    private var dismissal: Task<Void, Never>? = nil

    public init() {}

    /// Show where a song just went. Long enough to read at a glance and be
    /// believed, short enough that it is gone before it is in the way.
    /// A button needs time to reach, so the pill stays longer with one.
    public func show(_ destination: SaveDestination, count: Int = 1,
                     direction: SavedToast.Direction = .added, action: Toast.Action? = nil) {
        dismissal?.cancel()
        current = SavedToast(destination: destination, count: count,
                             direction: direction, action: action)
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(action == nil ? 1.9 : 3.5))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}

// MARK: - The pill

/// The message card with the destination's cover in place of the icon.
struct MixSavedToast: View {

    let toast: SavedToast
    var action: Toast.Action? = nil

    @EnvironmentObject private var library: LibraryService

    var body: some View {
        ToastChrome(message: toast.text, action: action) { cover }
            // Without a button it never eats taps.
            .allowsHitTesting(action != nil)
    }

    /// Plain tile if the playlist was deleted.
    @ViewBuilder
    private var cover: some View {
        if let playlist = library.playlist(id: toast.destination.playlistID) {
            PlaylistArtwork(playlist: playlist, size: 36, cornerRadius: 4)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.mixPrimary.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: toast.destination.fallbackIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                )
        }
    }
}

// MARK: - Host

/// Hosts the pill with its own spring, scoped so it doesn't animate the window.
public struct SavedToastHost: View {

    @ObservedObject private var center: SavedToastCenter
    /// Gap below the pill; carried by the pill so an empty host takes no space.
    private let bottomGap: CGFloat

    public init(center: SavedToastCenter, bottomGap: CGFloat = 0) {
        self.center = center
        self.bottomGap = bottomGap
    }

    public var body: some View {
        ZStack {
            if let toast = center.current {
                MixSavedToast(toast: toast, action: toast.action.map { a in
                    Toast.Action(title: a.title) { center.dismiss(); a.run() }
                })
                    .padding(.bottom, bottomGap)
                    .id(toast.id)
                    .transition(Self.transition)
            }
        }
        .mixAnimation(Self.animation, value: center.current)
    }

    /// Up from below like the bar toast. No scale (re-rasterises every frame).
    static var transition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    /// Slightly overdamped.
    static var animation: Animation {
        .mixSnappy
    }
}

// MARK: - Save pop

/// Save bounce: press in, overshoot back, ring expands out. Fires on an explicit
/// trigger, not saved state, or every copy on screen would bounce.
struct SavePop: ViewModifier {

    /// Removal: ring closes in, no overshoot.
    enum Direction { case save, remove }

    /// Bumped by the owner on each save. Any `Equatable` change fires it.
    let trigger: Int
    var direction: Direction = .save
    /// The control's accent.
    var tint: Color = .mixPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mixMotion) private var motion

    private struct Pop {
        var scale: Double = 1
        var ring: Double = 0.55
        var ringOpacity: Double = 0
    }

    func body(content: Content) -> some View {
        // Keyframe animators ignore the transaction, so check reduce motion directly.
        if reduceMotion || motion.isReduced {
            content
        } else {
            content.keyframeAnimator(initialValue: Pop(), trigger: trigger) { view, pop in
                view
                    .background {
                        Circle()
                            .strokeBorder(tint, lineWidth: 1.5)
                            .scaleEffect(pop.ring)
                            .opacity(pop.ringOpacity)
                    }
                    .scaleEffect(pop.scale)
            } keyframes: { _ in
                // Quick dip, longer overshoot. Cubic, not spring: spring keyframes keep settling
                // into the next tap. Removal drops the overshoot and reverses the ring.
                KeyframeTrack(\.scale) {
                    CubicKeyframe(isRemoval ? 0.84 : 0.78, duration: 0.09)
                    CubicKeyframe(isRemoval ? 0.94 : 1.14, duration: 0.13)
                    CubicKeyframe(1.0,  duration: 0.16)
                }
                KeyframeTrack(\.ring) {
                    LinearKeyframe(isRemoval ? 1.6 : 0.6, duration: 0.06)
                    CubicKeyframe(isRemoval ? 0.7 : 1.75, duration: 0.32)
                }
                KeyframeTrack(\.ringOpacity) {
                    LinearKeyframe(isRemoval ? 0.45 : 0.5, duration: 0.06)
                    CubicKeyframe(0, duration: 0.30)
                }
            }
        }
    }

    private var isRemoval: Bool { direction == .remove }
}

extension View {
    /// See `SavePop`. `trigger` is a counter the caller bumps on each save.
    func savePop(trigger: Int, tint: Color = .mixPrimary,
                 direction: SavePop.Direction = .save) -> some View {
        modifier(SavePop(trigger: trigger, direction: direction, tint: tint))
    }
}
