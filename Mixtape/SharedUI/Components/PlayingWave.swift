// The now-playing waveform on a row. Drawn by a platform image view: SwiftUI symbol effects redraw on
// the main thread every frame (and wait on the window server each time on macOS 26), these run in
// Core Animation.

import SwiftUI

struct PlayingWave: View {
    var size: CGFloat = 13
    let isPlaying: Bool
    /// The queue and the AppKit table pulse; other rows sweep.
    var pulses = false
    @Environment(\.mixMotion) private var motion

    var body: some View {
        WaveImage(size: size, pulses: pulses, waving: isPlaying && !motion.isReduced)
            .fixedSize()
            .accessibilityLabel("Now playing")
    }
}

#if os(macOS)
private struct WaveImage: NSViewRepresentable {
    let size: CGFloat
    let pulses: Bool
    let waving: Bool

    func makeNSView(context: Context) -> WaveImageView {
        let view = WaveImageView()
        view.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        view.contentTintColor = NSColor(Color.mixPrimary)
        view.pulses = pulses
        return view
    }

    func updateNSView(_ view: WaveImageView, context: Context) { view.waving = waving }
}

final class WaveImageView: NSImageView {
    var pulses = false
    /// Only touches the effect on a change, so a row update doesn't restart it.
    var waving = false {
        didSet {
            guard waving != oldValue else { return }
            removeAllSymbolEffects()
            guard waving else { return }
            if pulses { addSymbolEffect(.pulse, options: .repeating) }
            else { addSymbolEffect(.variableColor.iterative, options: .repeating) }
        }
    }
}
#else
private struct WaveImage: UIViewRepresentable {
    let size: CGFloat
    let pulses: Bool
    let waving: Bool

    func makeUIView(context: Context) -> WaveImageView {
        let view = WaveImageView(image: UIImage(systemName: "waveform",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)))
        view.tintColor = UIColor(Color.mixPrimary)
        view.pulses = pulses
        return view
    }

    func updateUIView(_ view: WaveImageView, context: Context) { view.waving = waving }
}

final class WaveImageView: UIImageView {
    var pulses = false
    /// Only touches the effect on a change, so a row update doesn't restart it.
    var waving = false {
        didSet {
            guard waving != oldValue else { return }
            removeAllSymbolEffects()
            guard waving else { return }
            if pulses { addSymbolEffect(.pulse, options: .repeating) }
            else { addSymbolEffect(.variableColor.iterative, options: .repeating) }
        }
    }
}
#endif
