// HomeView.swift
// Mixtape — Features/Home
//
// Shared landing screen for iOS and macOS. Surfaces a personalised greeting,
// recently played / recently added / favourite tracks, a compact listening
// stats card, and quick-links to the main library sections.
//
// No new injected dependencies: uses the existing AppDependencies (deps),
// PlaybackEngine (engine) and LibraryService (library) environment objects.

import SwiftUI

// MARK: - Quick-link destinations
//
// Platform-agnostic enum the quick-link chips emit. The host (MainTabView on
// iOS, MacContentRouter on macOS) maps these onto its own navigation model.

public enum HomeQuickLink: Hashable {
    case songs, albums, artists, playlists
}

public struct HomeView: View {

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    /// Invoked when a quick-link chip is tapped. Host translates to navigation.
    private let onQuickLink: (HomeQuickLink) -> Void

    @State private var showStats = false

    public init(onQuickLink: @escaping (HomeQuickLink) -> Void = { _ in }) {
        self.onQuickLink = onQuickLink
    }

    // MARK: Derived data

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Good night"
        }
    }

    private var displayName: String? {
        let name = deps.authService.currentUser?.displayName
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return nil
    }

    private var recentlyPlayed: [Track] { Array(engine.recentlyPlayed.prefix(12)) }

    private var recentlyAdded: [Track] {
        library.tracks
            .sorted { $0.dateImported > $1.dateImported }
            .prefix(10)
            .map { $0 }
    }

    /// Favourites detected via the Favourites system playlist when present,
    /// falling back to LibraryService.isFavourited per-track.
    private var favourites: [Track] {
        if let favPlaylist = library.playlists.first(where: { $0.isFavourites }) {
            let tracks = favPlaylist.trackIDs.compactMap { library.track(id: $0) }
            if !tracks.isEmpty { return Array(tracks.prefix(12)) }
        }
        return library.tracks
            .filter { library.isFavourited(trackID: $0.id) }
            .prefix(12)
            .map { $0 }
    }

    private var isLibraryEmpty: Bool { library.tracks.isEmpty }

    // MARK: Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if isLibraryEmpty {
                    emptyState
                } else {
                    quickLinks

                    if !recentlyPlayed.isEmpty {
                        carousel(title: "Jump back in", tracks: recentlyPlayed)
                    }
                    if !recentlyAdded.isEmpty {
                        carousel(title: "Recently added", tracks: recentlyAdded)
                    }
                    if !favourites.isEmpty {
                        carousel(title: "Your favourites", tracks: favourites)
                    }

                    statsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showStats) {
            ListeningStatsView()
                .environmentObject(deps)
                .environmentObject(engine)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.mixHeadline)
                .foregroundStyle(Color.mixTextPrimary)
            if let displayName {
                Text(displayName)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick links

    private var quickLinks: some View {
        let items: [(String, String, HomeQuickLink)] = [
            ("Songs",     MixtapeIcons.track,    .songs),
            ("Albums",    MixtapeIcons.album,    .albums),
            ("Artists",   MixtapeIcons.artist,   .artists),
            ("Playlists", MixtapeIcons.playlist, .playlists),
        ]
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(items, id: \.0) { title, icon, link in
                Button { onQuickLink(link) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.mixPrimary)
                            .frame(width: 24)
                        Text(title)
                            .font(.mixBodyBold)
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.mixSeparator, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Carousel

    private func carousel(title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(tracks) { track in
                        HomeTrackCard(track: track) {
                            Task { await engine.play(track: track, in: library.tracks) }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Listening stats

    private var statsCard: some View {
        let totalSecs = Int(library.tracks.map(\.duration).reduce(0, +))
        let totalDuration: String = {
            if totalSecs >= 3600 { return "\(totalSecs / 3600) hr \((totalSecs % 3600) / 60) min" }
            return "\(totalSecs / 60) min"
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Listening stats")
                Spacer()
                Button {
                    Haptics.play(.light)
                    showStats = true
                } label: {
                    Text("See all")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixPrimary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                StatTile(value: "\(library.tracks.count)", label: "Tracks", icon: MixtapeIcons.track)
                StatTile(value: "\(engine.recentlyPlayed.count)", label: "Played", icon: MixtapeIcons.clock)
                StatTile(value: totalDuration, label: "Library", icon: "hourglass")
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "music.note.house.fill",
            title: "Import music to get started",
            message: "Tracks you add and play will appear here."
        )
        .padding(.vertical, 40)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.mixTitle2)
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Track Card

private struct HomeTrackCard: View {
    let track: Track
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkThumbnail(
                    data: track.artworkData,
                    size: 140,
                    cornerRadius: 8,
                    placeholder: MixtapeIcons.track
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

                Text(track.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stat Tile

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
            Text(value)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.mixSeparator, lineWidth: 0.5)
        )
    }
}
