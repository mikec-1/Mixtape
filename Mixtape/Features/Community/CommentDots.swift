import SwiftUI

/// Timed comments on the post that's playing, as dots along a scrubber's track.
/// `inset` is how far the track starts in from the view's edges (a Slider's knob radius).
struct CommentDots: View {

    var queue: QueueService
    let duration: Double
    var inset: CGFloat = 0
    var color: Color = .mixPrimary

    private var marks: PlayingPostMarks { .shared }

    var body: some View {
        if marks.post != nil, marks.post == queue.currentTrack?.id, duration > 0 {
            GeometryReader { geo in
                let width = max(geo.size.width - inset * 2, 0)
                ForEach(marks.comments) { c in
                    Circle()
                        .fill(color)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 5, height: 5)
                        .position(x: inset + width * min(max((c.atSeconds ?? 0) / duration, 0), 1),
                                  y: geo.size.height / 2)
                        .help("\(c.author.name): \(c.body)")
                }
            }
            .accessibilityHidden(true)
        }
    }
}
