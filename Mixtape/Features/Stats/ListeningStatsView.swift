// ListeningStatsView.swift
// Mixtape — Features/Stats
//
// "Year in Mixtape" — a read-only listening dashboard over the play history:
// headline counts, top tracks & artists and a listening-by-hour chart.
// Period-switchable (30 days / this year / all time).

import SwiftUI

public struct ListeningStatsView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    @State private var period: StatsPeriod = .allTime
    @State private var stats: ListeningStats = .empty

    public init() {}

    public var body: some View {
        MixSheet(title: "Your Stats",
                 subtitle: "What you've actually been listening to.",
                 size: .large) {
            content
        }
        .onAppear(perform: recompute)
        .onChange(of: period) { _, _ in
            Haptics.play(.selection)
            recompute()
        }
    }

    private func recompute() {
        stats = deps.statsService.compute(period: period)
    }

    /// No `ScrollView` and no margins of its own — the sheet owns both, which
    /// is what lets the header and footer hairlines know when they're actually
    /// separating something.
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            periodPicker

            if stats.hasData {
                headlineGrid
                if let busiest = stats.busiestHour {
                    byHourCard(busiestHour: busiest)
                }
                if !stats.topTracks.isEmpty { topTracksSection }
                if !stats.topArtists.isEmpty { topArtistsSection }
            } else {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: "No listening yet",
                    message: "Play some music and your stats will appear here."
                )
                .padding(.top, 40)
            }
        }
    }

    // MARK: Period

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Headline numbers

    private var headlineGrid: some View {
        let minutes = stats.estimatedMinutes
        let hoursLabel: String = minutes >= 60
            ? "\(minutes / 60)h \(minutes % 60)m"
            : "\(minutes)m"
        // Three columns rather than the two this had as a 2×2: with the streak
        // card gone the fourth slot is empty, and a half-width card sitting
        // alone under a full row reads as something that failed to load.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            statCard(value: "\(stats.totalPlays)", label: "Plays", icon: MixtapeIcons.play)
            statCard(value: hoursLabel, label: "Listened", icon: "hourglass")
            statCard(value: "\(stats.uniqueTracks)", label: "Unique tracks", icon: MixtapeIcons.track)
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
            Text(value)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: By-hour chart

    private func byHourCard(busiestHour: Int) -> some View {
        let maxCount = max(stats.playsByHour.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("When you listen")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                Text("Peak \(hourLabel(busiestHour))")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = stats.playsByHour[hour]
                    let frac = CGFloat(count) / CGFloat(maxCount)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hour == busiestHour ? Color.mixPrimary : Color.mixSurface2)
                        .frame(height: max(3, frac * 80))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 80)
            HStack {
                Text("12a").font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
                Spacer()
                Text("12p").font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
                Spacer()
                Text("11p").font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(16)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hourLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12)\(hour < 12 ? "am" : "pm")"
    }

    // MARK: Top tracks

    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top tracks")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            ForEach(Array(stats.topTracks.enumerated()), id: \.element.id) { index, item in
                Button {
                    Haptics.play(.light)
                    Task { await engine.play(track: item.track, in: deps.libraryService.tracks, source: .playlist(id: Playlist.allSongsID, name: "All Songs")) }
                } label: {
                    rankedRow(
                        rank: index + 1,
                        artwork: item.track.displayArtwork,
                        placeholder: MixtapeIcons.track,
                        corner: 6,
                        title: item.track.title,
                        subtitle: item.track.artistName,
                        count: item.playCount
                    )
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
    }

    // MARK: Top artists

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top artists")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            ForEach(Array(stats.topArtists.enumerated()), id: \.element.id) { index, item in
                rankedRow(
                    rank: index + 1,
                    artwork: item.artworkData,
                    placeholder: MixtapeIcons.artist,
                    corner: 22,
                    title: item.name,
                    subtitle: nil,
                    count: item.playCount
                )
            }
        }
    }

    // MARK: Shared row

    private func rankedRow(
        rank: Int,
        artwork: Data?,
        placeholder: String,
        corner: CGFloat,
        title: String,
        subtitle: String?,
        count: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 22, alignment: .center)
            ArtworkThumbnail(data: artwork, size: 44, cornerRadius: corner, placeholder: placeholder)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("\(count) play\(count == 1 ? "" : "s")")
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
