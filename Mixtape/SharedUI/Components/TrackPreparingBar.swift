// TrackPreparingBar.swift
// Mixtape — SharedUI/Components
//
// The strip that says what the app is doing while a cold song loads.
//
// Playing something the app doesn't own yet is three pieces of work — find the
// upload, pull it down, convert it — and for as long as they run the only thing
// on screen was a spinner on the row. A spinner says "wait" and nothing else:
// not what it's waiting on, not whether it's nearly there, not whether it has
// quietly given up. People pressed play twice.
//
// So: the song's name, the step, the percentage when there is one, and a bar
// under it. It sits directly above the player — the place you are already
// looking once you have pressed play — and it goes away the moment sound
// starts.
//
// Small by default, because most of the time the answer is "a few seconds and
// it's fine". Click it (or the chevron, which appears under the pointer) and it
// opens: the song's full name, who it's by, and which of the three steps is
// running — for the times the answer is "this one is taking a while, why?".

import SwiftUI

public struct TrackPreparingBar: View {

    @ObservedObject private var coordinator: OnlinePlaybackCoordinator
    @ObservedObject private var unavailable = UnavailableTracks.shared

    /// Sticks once set. Someone who opened this card wanted the detail, and the
    /// next cold song is the one they wanted it for.
    @State private var isExpanded = false
    @State private var isHovering = false

    public init(coordinator: OnlinePlaybackCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        // Dropped songs stack above the spinner rather than replacing it: a run
        // of unfindable songs is skipped in a few seconds, and one card
        // overwriting the last would show only whichever lost the race. The
        // song now loading keeps its own place at the bottom.
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
        .mixAnimation(.spring(response: 0.32, dampingFraction: 0.86),
                      value: coordinator.preparing == nil)
        .mixAnimation(.spring(response: 0.32, dampingFraction: 0.86),
                      value: unavailable.recentSkips.count)
    }

    /// "<song> couldn't be found" — the same card, in red, with no progress to
    /// report. Same shape and same corner as the preparing card because it
    /// answers the same question: what happened to the song I was expecting.
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
        // Not a `Button` any more. The card carries its own Cancel button now,
        // and a button nested inside a button's label does not reliably receive
        // taps on iOS — the outer one swallows them. A tap gesture on the
        // content leaves the inner control as the only real button here.
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
        .onTapGesture { isExpanded.toggle() }
        .onHover { isHovering = $0 }
        .mixAnimation(.spring(response: 0.28, dampingFraction: 0.85), value: isExpanded)
        .help(isExpanded ? "Hide the detail" : "Show what's happening")
    }

    /// Abandons the song being prepared.
    ///
    /// A resolve is seconds of waiting that the user cannot otherwise get out
    /// of: the wrong row was clicked, and the only options were to sit through
    /// it or to play something else on top of it. The two platforms want
    /// different things from the control — a pointer can afford a small mark
    /// that stays out of the way until it is wanted, a thumb cannot — so this
    /// is one action drawn twice rather than one compromise drawn once.
    @ViewBuilder
    private var cancelButton: some View {
        Button {
            coordinator.cancelPreparing()
        } label: {
            #if os(macOS)
            // Quiet until the pointer is on the card, and never a layout jump:
            // it fades rather than appears, so the disclosure beside it doesn't
            // shift as the pointer arrives.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering ? Color.mixTextSecondary : Color.clear)
                .contentShape(Rectangle())
            #else
            // Always visible, and sized for a thumb rather than a pointer. The
            // glyph stays small — the 44pt square around it is what does the
            // work, and it is invisible.
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
                    // Closed, the step rides on the title's line rather than
                    // costing the card a second one.
                    phaseLine(for: preparing)
                }
            }

            Spacer(minLength: 6)

            #if os(macOS)
            cancelButton
            disclosure
            #else
            // On iOS the cancel target is 44pt tall, which would push the card
            // taller than the two lines it holds. Negative padding lets the hit
            // area overhang the text rows it sits beside without claiming the
            // height for itself.
            disclosure
            cancelButton
                .padding(.vertical, -12)
                .padding(.trailing, -10)
            #endif
        }
    }

    /// "downloading 43%" — the verb and the number together, because the number
    /// on its own at the far edge of the card read as a separate thing.
    private func phaseLine(for preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        HStack(spacing: 4) {
            Text(preparing.phaseLabel)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .lineLimit(1)

            // Only when there is a real number behind it. A percentage the app
            // made up is worse than no percentage: it sets a clock the work
            // isn't running against.
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

    /// A pointer can go looking for a control that isn't drawn yet; a finger
    /// can't, so the phone keeps the chevron visible and the Mac fades it in
    /// under the cursor.
    private var chevronOpacity: Double {
        #if os(macOS)
        return isHovering || isExpanded ? 1 : 0
        #else
        return 1
        #endif
    }

    // MARK: Expanded detail

    /// The three pieces of work, in order, with the running one called out.
    /// Which step it's on is the question the collapsed card answers in one
    /// word; this is the same answer with the other two steps left in for
    /// context — how much is done, and how much is still to come.
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

/// Determinate when a fraction is known, and a travelling sweep when it isn't —
/// rather than an empty track, which reads as stuck.
/// The thin capsule under a preparing card: a real fraction when the work can
/// report one, and a sweep when it can't. Shared with the full player, which
/// draws the same progress where its seek bar would be.
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
                        // See `AppVisibility`: a resolve that runs on while
                        // the app is away must not animate while it does.
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
