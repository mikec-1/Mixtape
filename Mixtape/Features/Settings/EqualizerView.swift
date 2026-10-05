// Cross-platform graphic EQ: enable toggle, preset picker and a vertical slider per band.
// Binds live to AudioEqualizer. The sliders are a custom drag control rather than a rotated
// `Slider`, so layout and hit-testing match on iOS and macOS.

import SwiftUI

public struct EqualizerView: View {

    @ObservedObject private var equalizer: AudioEqualizer

    /// True inside `MixSheet` on iOS, which supplies the title and margins.
    /// Inline in macOS Settings it's a card with its own heading and background.
    private let isEmbedded: Bool

    public init(equalizer: AudioEqualizer, isEmbedded: Bool = false) {
        self.equalizer = equalizer
        self.isEmbedded = isEmbedded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            presetPicker
            bands
            footnote
        }
        .padding(isEmbedded ? 0 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isEmbedded ? Color.clear : Color.mixBackground)
    }

    // MARK: - Header (title + enable toggle)

    /// Embedded, the sheet already says "Equalizer", so the switch gets a plain label.
    private var header: some View {
        HStack {
            if isEmbedded {
                Text("Enabled")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextPrimary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("10-band graphic EQ")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: $equalizer.isEnabled)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Color.mixPrimary))
        }
    }

    // MARK: - Preset picker

    private var presetPicker: some View {
        HStack(spacing: 12) {
            Text("Preset")
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)

            Picker("Preset", selection: presetBinding) {
                ForEach(EqualizerPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Color.mixPrimary)
            .disabled(!equalizer.isEnabled)

            Spacer()

            Button("Reset") { equalizer.reset() }
                .font(.mixButtonSmall)
                .foregroundStyle(Color.mixPrimary)
                .buttonStyle(.plain).mixHandCursor()
                .disabled(!equalizer.isEnabled)
        }
        .opacity(equalizer.isEnabled ? 1 : 0.5)
    }

    /// Picking "Custom" is a no-op (it has no fixed curve); other presets apply.
    private var presetBinding: Binding<EqualizerPreset> {
        Binding(
            get: { equalizer.preset },
            set: { newValue in
                if newValue != .custom { equalizer.apply(newValue) }
            }
        )
    }

    // MARK: - Band sliders

    private var bands: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(AudioEqualizer.frequencies.enumerated()), id: \.offset) { index, freq in
                VStack(spacing: 6) {
                    Text(gainLabel(for: index))
                        .font(.mixMicro)
                        .monospacedDigit()
                        .foregroundStyle(Color.mixTextTertiary)

                    EQBandSlider(
                        value: bandBinding(index),
                        range: AudioEqualizer.gainRange,
                        enabled: equalizer.isEnabled,
                        label: "\(frequencyLabel(freq)) hertz"
                    )
                    .frame(height: 140)

                    Text(frequencyLabel(freq))
                        .font(.mixMicro)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(equalizer.isEnabled ? 1 : 0.5)
    }

    private func bandBinding(_ index: Int) -> Binding<Float> {
        Binding(
            get: { equalizer.gains.indices.contains(index) ? equalizer.gains[index] : 0 },
            set: { equalizer.setGain($0, forBand: index) }
        )
    }

    private func gainLabel(for index: Int) -> String {
        let g = equalizer.gains.indices.contains(index) ? equalizer.gains[index] : 0
        let rounded = (g * 10).rounded() / 10
        return rounded > 0 ? "+\(Int(rounded.rounded()))" : "\(Int(rounded.rounded()))"
    }

    private func frequencyLabel(_ freq: Float) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    private var footnote: some View {
        Text("Adjustments apply instantly and are saved for next launch.")
            .font(.mixCaption)
            .foregroundStyle(Color.mixTextTertiary)
    }
}

// MARK: - Custom vertical band slider

/// Vertical drag slider with a 0 dB centre line. Only DragGesture and GeometryReader, so it works on both platforms.
private struct EQBandSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let enabled: Bool
    /// Spoken band name, e.g. "1k hertz". The visible label is a two-letter abbreviation.
    let label: String

    /// One accessibility increment in dB, matching the readout.
    private let step: Float = 1

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0.5
            let knobY = height * (1 - CGFloat(fraction))

            ZStack(alignment: .top) {
                // Track
                Capsule()
                    .fill(Color.mixSurface2)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)

                // Centre (0 dB) reference line
                Rectangle()
                    .fill(Color.mixSeparator)
                    .frame(height: 1)
                    .offset(y: height / 2)

                // Active fill between centre and knob
                fillSegment(height: height, knobY: knobY)

                // Knob. 20pt so a fingertip can place it.
                Circle()
                    .fill(enabled ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity)
                    .offset(y: knobY - 10)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let clampedY = min(max(0, g.location.y), height)
                        let newFraction = 1 - (clampedY / height)
                        value = range.lowerBound + Float(newFraction) * span
                    }
            )
            .allowsHitTesting(enabled)
        }
        .frame(maxWidth: .infinity)
        // Gives VoiceOver a label and the swipe up/down of a real Slider.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(gainDescription)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }

    }

    /// What the value sounds like: the readout above the slider, spoken.
    private var gainDescription: String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "plus \(rounded) decibels" : "\(rounded) decibels"
    }

    @ViewBuilder
    private func fillSegment(height: CGFloat, knobY: CGFloat) -> some View {
        let centerY = height / 2
        let top = min(centerY, knobY)
        let segHeight = abs(centerY - knobY)
        Capsule()
            .fill(enabled ? Color.mixPrimary.opacity(0.7) : Color.mixTextTertiary.opacity(0.5))
            .frame(width: 4, height: segHeight)
            .frame(maxWidth: .infinity)
            .offset(y: top)
    }
}

#Preview {
    EqualizerView(equalizer: AudioEqualizer())
        .frame(width: 460)
        .background(Color.mixBackground)
}
