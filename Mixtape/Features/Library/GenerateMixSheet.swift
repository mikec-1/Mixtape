// GenerateMixSheet.swift
// Mixtape — Features/Library
//
// "Make me a playlist": pick a vibe, decide how much of it should be music you
// already own, and get a playlist. The engine is `MixGenerator`; this is the
// brief.

import SwiftUI

struct GenerateMixSheet: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var vibe: MixVibe = .yourTaste
    /// How much of the result comes from the library, 0…1. Half is the honest
    /// default: the feature is as much "rediscover what you have" as it is
    /// "find me something new", and starting at either end hides one of them.
    @State private var libraryShare: Double = 0.5
    @State private var count: Double = Double(MixGenerator.defaultCount)

    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        MixSheet(title: "Generate a Mix",
                 subtitle: "Pick a mood and how much of it should be music you already have.",
                 size: .large,
                 primary: MixSheetAction("Generate",
                                         isEnabled: !isWorking,
                                         isBusy: isWorking,
                                         action: { Task { await generate() } })) {
            VStack(alignment: .leading, spacing: 22) {
                vibePicker
                blendSlider
                lengthStepper

                if let error {
                    Text(error)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixDestructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Vibe

    private var vibePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Vibe")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 240), spacing: 8)],
                      spacing: 8) {
                ForEach(MixVibe.presets) { preset in
                    Button {
                        Haptics.play(.light)
                        withMixAnimation(.snappy(duration: 0.18)) { vibe = preset }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 13, weight: .semibold))
                            Text(preset.title)
                                .font(.mixLabel)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(preset == vibe ? Color.mixBackground : Color.mixTextPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                        .background(preset == vibe ? Color.mixPrimary : Color.mixSurface2)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityAddTraits(preset == vibe ? [.isSelected] : [])
                }
            }

            Text(vibe.blurb)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
        }
    }

    // MARK: - Blend

    private var blendSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Blend")

            Slider(value: $libraryShare, in: 0...1, step: 0.05)
                .tint(Color.mixPrimary)

            HStack {
                Text("All new to me")
                Spacer(minLength: 8)
                // The number, not the percentage: "12 of 25 from your library"
                // is the thing the slider actually decides.
                Text("\(fromLibrary) of \(Int(count)) from your library")
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer(minLength: 8)
                Text("All mine")
            }
            .font(.mixCaption)
            .foregroundStyle(Color.mixTextSecondary)
        }
    }

    private var fromLibrary: Int { Int((count * libraryShare).rounded()) }

    // MARK: - Length

    private var lengthStepper: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Length")
            HStack {
                Text("\(Int(count)) songs")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer(minLength: 12)
                Stepper("Songs", value: $count, in: Self.countBounds, step: 5)
                    .labelsHidden()
            }
        }
    }

    private static let countBounds: ClosedRange<Double> =
        Double(MixGenerator.countRange.lowerBound)...Double(MixGenerator.countRange.upperBound)

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.mixLabel)
            .foregroundStyle(Color.mixTextSecondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    // MARK: - Generate

    private func generate() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }

        let mix = await MixGenerator.generate(vibe: vibe,
                                              libraryShare: libraryShare,
                                              count: Int(count),
                                              library: deps.libraryService,
                                              stats: deps.statsService,
                                              catalog: deps.itunesClient)

        guard !mix.isEmpty else {
            // Two different failures, and the difference matters: one is fixed
            // by importing music, the other by being online.
            error = libraryShare >= 1
                ? "Nothing in your library matches that vibe yet. Try a different one, or slide towards new music."
                : "Couldn't reach the catalogue, and your library had nothing matching that vibe. Check your connection and try again."
            return
        }

        let saved = deps.importService.saveOnlinePlaylist(
            name:        mix.name,
            description: mix.description,
            coverURLs:   mix.covers,
            origin:      .mix,
            ownerName:   "Mixtape",
            tracks:      mix.onlineTracks,
            leadingTrackIDs: mix.libraryTrackIDs
        )

        guard saved != nil else {
            error = "None of the songs could be saved. Check your connection and try again."
            return
        }
        Haptics.play(.success)
        dismiss()
    }
}
