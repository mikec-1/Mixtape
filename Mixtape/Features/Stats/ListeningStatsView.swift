// "Year in Mixtape": a read-only dashboard over play history. Counts, top tracks and
// artists, and listening by hour, for 30 days / this year / all time.

import SwiftUI
import Charts

public struct ListeningStatsView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @State private var period: StatsPeriod = .allTime
    @State private var stats: ListeningStats = .empty
    @State private var showHistory = false
    /// Install names by device id, for the device split. They live on the server.
    @State private var deviceNames: [String: String] = [:]

    public init() {}

    public var body: some View {
        MixSheet(title: "Your Stats",
                 subtitle: "What you've actually been listening to.",
                 size: .large) {
            content
        }
        .onAppear(perform: recompute)
        .task { deviceNames = await deps.syncService.deviceNames() }
        .onChange(of: period) { _, _ in
            Haptics.play(.selection)
            recompute()
        }
        // Recomputed on the way back: the history page can clear the log.
        .sheet(isPresented: $showHistory, onDismiss: recompute) {
            ListeningHistoryView()
                .environment(deps)
                .environment(engine)
        }
    }

    private func recompute() {
        stats = deps.statsService.compute(period: period)
    }

    /// No ScrollView or margins: the sheet owns both.
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            periodPicker

            if stats.hasData {
                headlineGrid
                overTimeCard
                heatmapCard
                if let busiest = stats.busiestHour {
                    byHourCard(busiestHour: busiest)
                }
                if !stats.topTracks.isEmpty { topTracksSection }
                if !stats.topArtists.isEmpty { topArtistsSection }
                if !stats.topAlbums.isEmpty { topAlbumsSection }
                if !stats.topGenres.isEmpty {
                    barsCard(title: "Genres", rows: stats.topGenres.map { ($0.name, $0.playCount) })
                }
                // One device is a single full bar, which says nothing.
                if deviceRows.count > 1 { barsCard(title: "Devices", rows: deviceRows) }
                historyLink
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
        // Three columns so there's no lone card on a second row.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            statCard(value: "\(stats.totalPlays)", label: "Plays", icon: MixtapeIcons.play)
            statCard(value: hoursLabel, label: "Listened", icon: "hourglass")
            statCard(value: "\(stats.uniqueTracks)", label: "Unique tracks", icon: MixtapeIcons.track)
            if let new = stats.newTracks {
                let rate = Int((Double(new) / Double(max(stats.uniqueTracks, 1)) * 100).rounded())
                statCard(value: "\(new)", label: "New to you, \(rate)%", icon: "sparkles")
            } else {
                statCard(value: "\(stats.playsByDay.count)", label: "Days played", icon: "calendar")
            }
            statCard(value: "\(stats.currentStreak)", label: "Day streak", icon: "flame")
            statCard(value: "\(stats.bestStreak)", label: "Best streak", icon: "trophy")
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

    // MARK: Chart cards

    /// The cards' shared chrome: a title, a detail on the right, the surface.
    private func chartCard<Content: View>(title: String, detail: String? = nil,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                }
            }
            content()
        }
        .padding(16)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Plays per day, week or month across the period: the one chart with time on it.
    private var overTimeCard: some View {
        let detail = switch stats.seriesUnit {
        case .day:        "Per day"
        case .weekOfYear: "Per week"
        default:          "Per month"
        }
        return chartCard(title: "Listening over time", detail: detail) {
            Chart(stats.series) { point in
                BarMark(x: .value("Date", point.start, unit: stats.seriesUnit),
                        y: .value("Plays", point.plays))
                    .foregroundStyle(Color.mixPrimary)
                    .cornerRadius(2)
            }
            .frame(height: 160)
        }
    }

    /// A square per day, weeks as columns, stronger for more plays. Drawn by hand like
    /// the by-hour bars, since Swift Charts has no calendar grid. At most a year.
    private var heatmapCard: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yearAgo = cal.date(byAdding: .weekOfYear, value: -52, to: today) ?? today
        let first = cal.startOfDay(for: max(stats.period.startDate() ?? stats.firstPlay ?? today, yearAgo))
        let weekStart = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        let lead = cal.dateComponents([.day], from: weekStart, to: first).day ?? 0
        let days = (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let columns = max(1, (lead + days + 6) / 7)
        let peak = max(stats.playsByDay.values.max() ?? 1, 1)
        let active = stats.playsByDay.keys.filter { $0 >= first }.count
        return chartCard(title: "Days you listened", detail: "\(active) of \(days)") {
            Canvas { context, size in
                let gap: CGFloat = 2
                let side = min((size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                               (size.height - gap * 6) / 7)
                for offset in 0..<days {
                    guard let day = cal.date(byAdding: .day, value: offset, to: first) else { continue }
                    let plays = stats.playsByDay[cal.startOfDay(for: day)] ?? 0
                    let slot = lead + offset
                    let rect = CGRect(x: CGFloat(slot / 7) * (side + gap), y: CGFloat(slot % 7) * (side + gap),
                                      width: side, height: side)
                    let fill = plays == 0
                        ? Color.mixSurface2
                        : Color.mixPrimary.opacity(0.3 + 0.7 * Double(plays) / Double(peak))
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, side / 4)), with: .color(fill))
                }
            }
            .gpuRendered()
            .aspectRatio(CGFloat(columns) / 7, contentMode: .fit)
            .frame(maxHeight: 7 * 16 + 6 * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel("Listened on \(active) of the last \(days) days")
        }
    }

    /// A short ranked list as horizontal bars: genres, devices.
    private func barsCard(title: String, rows: [(name: String, plays: Int)]) -> some View {
        chartCard(title: title) {
            Chart(Array(rows.enumerated()), id: \.offset) { item in
                BarMark(x: .value("Plays", item.element.plays), y: .value(title, item.element.name))
                    .foregroundStyle(Color.mixPrimary)
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(item.element.plays)")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextSecondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(rows.count) * 32)
        }
    }

    /// Plays per install, named from the `devices` table. An id with no name (a device
    /// since removed, or offline) folds into "Other devices".
    private var deviceRows: [(name: String, plays: Int)] {
        var named: [String: Int] = [:]
        for (id, plays) in stats.devicePlays {
            let name = id == AppDependencies.deviceID
                ? SupabaseSyncService.deviceName
                : deviceNames[id] ?? "Other devices"
            named[name, default: 0] += plays
        }
        return named.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Top albums

    private var topAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top albums")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            ForEach(Array(stats.topAlbums.enumerated()), id: \.element.id) { index, item in
                rankedRow(rank: index + 1, artwork: item.artworkData, placeholder: MixtapeIcons.album,
                          corner: 6, title: item.title, subtitle: item.artist, count: item.playCount)
            }
        }
    }

    /// ▲3 / ▼1 / NEW against the period before. Nothing for a row holding its place.
    @ViewBuilder
    private func moveBadge(_ move: RankMove) -> some View {
        switch move {
        case .new:
            Text("NEW")
                .foregroundStyle(Color.mixPrimary)
                .accessibilityLabel("New entry")
        case .moved(let places) where places > 0:
            Text("▲\(places)")
                .foregroundStyle(Color.mixSuccess)
                .accessibilityLabel("Up \(places)")
        case .moved(let places) where places < 0:
            Text("▼\(-places)")
                .foregroundStyle(Color.mixDestructive)
                .accessibilityLabel("Down \(-places)")
        case .moved:
            EmptyView()
        }
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
                        count: item.playCount,
                        movement: item.movement
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
                    count: item.playCount,
                    movement: item.movement
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
        count: Int,
        movement: RankMove? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text("\(rank)")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextTertiary)
                if let movement {
                    moveBadge(movement)
                        .font(.system(.caption2, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 30, alignment: .center)
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

    // MARK: History

    /// The log itself, one level down: this page is the summary, not the list.
    private var historyLink: some View {
        Button {
            Haptics.play(.light)
            showHistory = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: MixtapeIcons.clock)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening history")
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("Every play, newest first")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .padding(16)
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}
