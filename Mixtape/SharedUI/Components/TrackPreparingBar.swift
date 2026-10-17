// Strip above the player while a cold song loads: song name, step, percentage
// when known, and a bar. Gone once sound starts. Tap to expand into the full
// name, artist and the three steps (find, download, convert).

import SwiftUI

public struct TrackPreparingBar: View {

    @ObservedObject private var coordinator: OnlinePlaybackCoordinator
    @ObservedObject private var unavailable = UnavailableTracks.shared

    /// Sticks once opened.
    @State private var isExpanded = false
    @State private var isHovering = false

    public init(coordinator: OnlinePlaybackCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        // Dropped songs stack above the spinner so a run of skips all show; the
        // loading song stays at the bottom.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(unavailable.recentSkips) { dropped in
                unfindableCard(dropped)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let preparing = coordinator.preparing {
                card(for: preparing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .mixAnimation(.mixSnappy,
                      value: coordinator.preparing == nil)
        .mixAnimation(.mixSnappy,
                      value: unavailable.recentSkips.count)
    }

    /// "<song> couldn't be found": the same card in red, no progress.
    private func unfindableCard(_ dropped: UnavailableTracks.Announcement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(dropped.title) couldn't be found")
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Skipped — \(dropped.artist)")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mixSurface2)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.55), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { unavailable.dismiss(dropped) }
        .help("Nothing online matches this song, so the queue skipped it")
    }

    private func card(for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        // A tap gesture, not a `Button`: the inner Cancel button doesn't get taps
        // inside a button's label on iOS.
        VStack(alignment: .leading, spacing: isExpanded ? 9 : 7) {
            titleRow(for: preparing)

            if isExpanded {
                steps(for: preparing)
            }

            PreparingProgressTrack(fraction: preparing.progress.fraction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: isExpanded ? 320 : 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mixSurface2)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.mixSeparator.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mixTapAction { isExpanded.toggle() }
        .onHover { isHovering = $0 }
        .mixAnimation(.mixSnappy, value: isExpanded)
        .help(isExpanded ? "Hide the detail" : "Show what's happening")
    }

    /// Cancel the song being prepared. Small hover mark on macOS, a 44pt target on iOS.
    @ViewBuilder
    private var cancelButton: some View {
        Button {
            coordinator.cancelPreparing()
        } label: {
            #if os(macOS)
            // Fades in on hover so nothing shifts.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering ? Color.mixTextSecondary : Color.clear)
                .contentShape(Rectangle())
            #else
            // Always visible; small glyph, 44pt invisible target.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(.plain).mixHandCursor()
        .help("Stop preparing this song")
        .accessibilityLabel("Stop preparing this song")
    }

    // MARK: Collapsed line

    @ViewBuilder
    private func titleRow(for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preparing.title)
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(.leading)
                    // Open, the whole point is seeing the name that was cut off.
                    .lineLimit(isExpanded ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: isExpanded)

                if isExpanded {
                    Text(preparing.artist)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .lineLimit(1)
                } else {
                    // Collapsed, the step shares the title's line.
                    phaseLine(for: preparing)
                }
            }

            Spacer(minLength: 6)

            #if os(macOS)
            cancelButton
            disclosure
            #else
            // Negative padding so the 44pt target doesn't make the card taller.
            disclosure
            cancelButton
                .padding(.vertical, -12)
                .padding(.trailing, -10)
            #endif
        }
    }

    /// "downloading 43%": verb and number together.
    private func phaseLine(for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        HStack(spacing: 4) {
            Text(preparing.phaseLabel)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .lineLimit(1)

            // Only a real percentage, never an invented one.
            if let percent = percent(preparing) {
                Text("\(percent)%")
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var disclosure: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.mixTextTertiary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .padding(.top, 1)
            .opacity(chevronOpacity)
            .mixAnimation(.easeOut(duration: 0.15), value: isHovering)
    }

    /// Always visible on iOS; fades in on hover on the Mac.
    private var chevronOpacity: Double {
        #if os(macOS)
        return isHovering || isExpanded ? 1 : 0
        #else
        return 1
        #endif
    }

    // MARK: Expanded detail

    /// The three steps in order, the running one highlighted.
    private func steps(for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ResolveProgress.Phase.ordered, id: \.self) { phase in
                stepRow(phase, for: preparing)
            }
        }
    }

    private func stepRow(_ phase: ResolveProgress.Phase,
                         for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        let state = state(of: phase, in: preparing.progress.phase)
        return HStack(spacing: 7) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(state == .done ? Color.mixPrimary
                                                : (state == .running ? Color.mixTextSecondary
                                                                     : Color.mixTextTertiary.opacity(0.6)))
                .frame(width: 12)

            Text(phase.stepLabel)
                .font(.mixCaption)
                .foregroundStyle(state == .pending ? Color.mixTextTertiary : Color.mixTextSecondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if state == .running, let percent = percent(preparing) {
                Text("\(percent)%")
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextSecondary)
                    .monospacedDigit()
            }
        }
    }

    private enum StepState {
        case done, running, pending

        var symbol: String {
            switch self {
            case .done:    return "checkmark.circle.fill"
            case .running: return "arrow.down.circle.fill"
            case .pending: return "circle"
            }
        }
    }

    private func state(of phase: ResolveProgress.Phase,
                       in current: ResolveProgress.Phase) -> StepState {
        if phase == current { return .running }
        return phase.order < current.order ? .done : .pending
    }

    private func percent(_ preparing: OnlinePlaybackCoordinator.PreparingTrack) -> Int? {
        guard let fraction = preparing.progress.fraction else { return nil }
        return Int((fraction * 100).rounded())
    }
}

// MARK: - Phases, spelled out

private extension ResolveProgress.Phase {

    static var ordered: [ResolveProgress.Phase] { [.searching, .downloading, .converting] }

    var order: Int {
        switch self {
        case .searching:   return 0
        case .downloading: return 1
        case .converting:  return 2
        }
    }

    /// Longer than `phaseLabel`, which has to fit beside a song title.
    var stepLabel: String {
        switch self {
        case .searching:   return "Finding the audio"
        case .downloading: return "Downloading"
        case .converting:  return "Finishing up"
        }
    }
}

// MARK: - The bar itself

/// Thin bar under a preparing card: a real fraction when known, else a sweep.
/// Also used by the full player in place of its seek bar.
struct PreparingProgressTrack: View {

    let fraction: Double?
    @State private var sweep: CGFloat = -0.4
    @ObservedObject private var visibility = AppVisibility.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.mixTextTertiary.opacity(0.25))

                if let fraction {
                    Capsule()
                        .fill(Color.mixPrimary)
                        .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                        .mixAnimation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    Capsule()
                        .fill(Color.mixPrimary)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: sweep * geo.size.width)
                        .onAppear { startSweep() }
                        // No animating in the background. See `AppVisibility`.
                        .onChange(of: visibility.isForeground) { _, _ in startSweep() }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }

    private func startSweep() {
        guard visibility.isForeground else {
            withAnimation(nil) { sweep = -0.4 }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
            sweep = 1.0
        }
    }
}
