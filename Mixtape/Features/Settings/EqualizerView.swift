// EqualizerView.swift
// Mixtape — Features/Settings
//
// Reusable cross-platform graphic-EQ UI: an enable toggle, a preset picker,
// and a vertical gain slider per band. Binds live to AudioEqualizer so moving
// a slider is heard immediately and persists across relaunches.
//
// The vertical sliders are drawn with a custom gesture-driven control rather
// than a rotated `Slider`, so layout and hit-testing behave identically on
// iOS and macOS.

import SwiftUI

public struct EqualizerView: View {

    @ObservedObject private var equalizer: AudioEqualizer

    public init(equalizer: AudioEqualizer) {
        self.equalizer = equalizer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            presetPicker
            bands
            footnote
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixBackground)
    }

    // MARK: - Header (title + enable toggle)

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Equalizer")
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("10-band graphic EQ")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
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
                .buttonStyle(.plain)
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
                        enabled: equalizer.isEnabled
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

/// A vertical, gesture-driven slider with a centre (0 dB) reference line.
/// Cross-platform: relies only on DragGesture and GeometryReader.
private struct EQBandSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let enabled: Bool

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

                // Knob
                Circle()
                    .fill(enabled ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: 16, height: 16)
                    .frame(maxWidth: .infinity)
                    .offset(y: knobY - 8)
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
