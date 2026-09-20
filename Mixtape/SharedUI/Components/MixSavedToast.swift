// MixSavedToast.swift
// Mixtape — SharedUI/Components
//
// Two halves of the same moment: the pop the save control makes when you tap
// it, and the small pill at the bottom that says where the song went.
//
// They exist because saving got quieter than it should be. The check appearing
// in place of the plus is the whole confirmation a Discover row gives, and it
// is easy to miss on a list where four other rows already show one — while
// "which playlist did that go to?" is the actual question after a menu tap,
// and no answer was on screen at all.
//
// The pill wears the destination's own cover, which is the part that makes it
// answerable at a glance: you recognise the playlist you just used before you
// have finished reading its name. `PlaylistArtwork` draws it, so it is the
// same tile the sidebar shows — including the heart for Favourites and the
// note for the library, which are stand-ins there too.

import SwiftUI
import Combine

// MARK: - Destination

/// Where a song just landed.
///
/// All three are playlists underneath — Favourites and the library are system
/// rows in the same table — so the case carries an id and the card resolves the
/// real cover from it. The name rides along rather than being looked up: a
/// playlist deleted in the second the card is up should still say what it said
/// when the song went in.
public enum SaveDestination: Equatable, Hashable {
    case library
    case favourites
    /// Both at once, from one gesture: favouriting a song that wasn't saved yet
    /// saves it on the way. Its own case rather than two cards, because the pill
    /// shows one at a time — the first would be replaced before it was read.
    case libraryAndFavourites
    case playlist(id: UUID, name: String)

    /// The row to draw the cover from.
    var playlistID: UUID {
        switch self {
        case .library:          Playlist.allSongsID
        // The favourites cover: the more specific of the two things that
        // happened, and the one the gesture was actually about.
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

/// One showing of the pill. Carries an id so that saving twice to the same
/// place is two separate appearances — without it the second save is an equal
/// value, SwiftUI sees no change, and the pill sits there looking stale
/// instead of arriving again.
public struct SavedToast: Identifiable, Equatable {

    /// Which way the song moved. The pill is the same object either way — same
    /// cover, same corner, same timing — because "where did that go?" and "what
    /// did I just undo?" are the same question asked a second apart.
    public enum Direction { case added, removed }

    public let id = UUID()
    public let destination: SaveDestination
    /// How many songs went in. Only ever > 1 from a multi-select add.
    public let count: Int
    public let direction: Direction

    public init(destination: SaveDestination, count: Int = 1,
                direction: Direction = .added) {
        self.destination = destination
        self.count = count
        self.direction = direction
    }

    /// "Added to Roadtrip" / "3 songs added to Roadtrip". The count only earns
    /// its place when it tells you something — for one song it is noise, and
    /// this pill has very little room to spend on noise.
    var text: String {
        let verb = direction == .added ? "Added to" : "Removed from"
        return count == 1 ? "\(verb) \(destination.name)"
                          : "\(count) songs \(verb.lowercased()) \(destination.name)"
    }
}

// MARK: - Presenter

/// Owns the currently showing pill, and nothing else.
///
/// Deliberately its own object rather than another `@Published` on
/// `AppDependencies`. Everything in the app observes `deps`, so publishing the
/// pill from there invalidated the entire view tree twice per save — and a
/// Discover page can be holding fifty `SaveToLibraryButton`s that each rescan
/// the library on redraw. The animation was competing with a full re-render of
/// the app for its first frames, which is exactly what "a bit laggy" looks
/// like. Held as a plain `let`, so reading `deps.savedToasts` subscribes to
/// nothing and only the pill's own host redraws.
@MainActor
public final class SavedToastCenter: ObservableObject {

    @Published public private(set) var current: SavedToast? = nil

    private var dismissal: Task<Void, Never>? = nil

    public init() {}

    /// Show where a song just went. Long enough to read at a glance and be
    /// believed, short enough that it is gone before it is in the way.
    public func show(_ destination: SaveDestination, count: Int = 1,
                     direction: SavedToast.Direction = .added) {
        dismissal?.cancel()
        current = SavedToast(destination: destination, count: count,
                             direction: direction)
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.9))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

// MARK: - The pill

/// The small bar that slides up at the bottom and goes away on its own.
///
/// Hugs its content rather than spanning the width: it is a glance, and a
/// full-width bar is the shape this app already uses for sentences the user
/// has to actually read. Capped so a playlist named a whole sentence can't
/// push it edge to edge.
struct MixSavedToast: View {

    let toast: SavedToast

    @EnvironmentObject private var library: LibraryService

    var body: some View {
        HStack(spacing: 10) {
            cover
            Text(toast.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 340, alignment: .leading)
        // A solid fill, not a material. The pill animates on every save and a
        // live blur has to re-sample whatever is scrolling underneath it for
        // each frame of the slide — the one place in this app where the cost
        // lands squarely on an animation the user is watching.
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mixSeparator.opacity(0.8), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.32), radius: 14, y: 5)
        // Purely informational — it must never eat the tap meant for the row
        // or the player control underneath it.
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(toast.text)
    }

    /// The destination's real cover, via the same component the sidebar uses.
    /// Falls back to a plain tile only if the playlist has been deleted out
    /// from under the pill.
    @ViewBuilder
    private var cover: some View {
        if let playlist = library.playlist(id: toast.destination.playlistID) {
            PlaylistArtwork(playlist: playlist, size: 38, cornerRadius: 5)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.mixPrimary.opacity(0.15))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: toast.destination.fallbackIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                )
        }
    }
}

// MARK: - Host

/// Renders whatever the centre is currently showing, and owns the animation
/// for it.
///
/// A view of its own so the spring is scoped to the pill. Hung on a root as
/// `.animation(_:value:)` it belonged to the whole window, and every unrelated
/// change that happened to land in the same frame got dragged into the same
/// spring.
public struct SavedToastHost: View {

    @ObservedObject private var center: SavedToastCenter
    /// Room to leave under the pill when something else shares the corner.
    /// Carried by the pill rather than by the stack above it, so an empty host
    /// contributes nothing at all — as a `VStack` child it would otherwise take
    /// its spacing even while showing nothing, and quietly lift whatever sits
    /// below it by that much forever.
    private let bottomGap: CGFloat

    public init(center: SavedToastCenter, bottomGap: CGFloat = 0) {
        self.center = center
        self.bottomGap = bottomGap
    }

    public var body: some View {
        ZStack {
            if let toast = center.current {
                MixSavedToast(toast: toast)
                    .padding(.bottom, bottomGap)
                    .id(toast.id)
                    .transition(Self.transition)
            }
        }
        .mixAnimation(Self.animation, value: center.current)
    }

    /// Up from below, the way the bar toast already arrives — the two share a
    /// corner and would look like different features if they entered
    /// differently. Deliberately not a scale: scaling a shadowed, stroked pill
    /// re-rasterises it every frame for no legibility gained.
    static var transition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    /// Slightly overdamped. A bouncy arrival reads as playful the first time
    /// and as slow by the tenth, and this is a control people use constantly.
    static var animation: Animation {
        .spring(response: 0.34, dampingFraction: 0.86)
    }
}

// MARK: - Save pop

/// The bounce a save control makes on the tap that saves.
///
/// Modelled on Spotify's: the glyph is pressed *in* first and then overshoots
/// coming back, which is what makes it feel like a button taking a press rather
/// than an icon being swapped. A ring leaves the glyph at the same moment and
/// fades out past the edge of the frame, so the confirmation is visible from
/// the corner of the eye on a list where several rows already show a check.
///
/// Fires on an explicit trigger, never on the saved state itself: that state is
/// derived from the library, so a save made in the player would otherwise set
/// every copy of this button on screen bouncing at once.
struct SavePop: ViewModifier {

    /// Which gesture the bounce is confirming. The removal is the save played
    /// backwards — the ring closes *in* on the glyph instead of leaving it, and
    /// the overshoot is dropped, so undoing a save reads as a smaller event
    /// than making one without becoming a different animation.
    enum Direction { case save, remove }

    /// Bumped by the owner on each save. Any `Equatable` change fires it.
    let trigger: Int
    var direction: Direction = .save
    /// Ring colour — the control's own accent, so a heart pulses red and a save
    /// pulses brand.
    var tint: Color = .mixPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mixMotion) private var motion

    private struct Pop {
        var scale: Double = 1
        var ring: Double = 0.55
        var ringOpacity: Double = 0
    }

    func body(content: Content) -> some View {
        // A keyframe animator drives itself off its trigger and never consults
        // the transaction, so it has to be asked directly.
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
                // Down fast, up past 1, settle. The dip is deliberately shorter
                // than the overshoot — a slow squash looks like lag, a slow
                // release looks like spring. Cubic on the way back rather than
                // a spring: a spring keyframe keeps solving after it looks
                // finished, and two of them back to back left the glyph
                // perceptibly still moving under the next tap.
                //
                // Removal is the same shape with the overshoot taken out and the
                // ring run inwards: undoing a save should read as the smaller
                // event it is, without being a different animation.
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
