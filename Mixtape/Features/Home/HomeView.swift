// HomeView.swift
// Mixtape — Features/Home
//
// Shared landing screen — iOS + macOS. A lively, Spotify-style home that
// reflects an app with BOTH an offline and an online player: a personalised
// greeting + featured hero card, a "Jump back in" grid, recent-artist avatars,
// a "Made for you" recommendations row, recently added / favourites carousels,
// a compact quick-links grid and a listening-stats card.
//
// No new injected dependencies: uses existing AppDependencies (deps),
// PlaybackEngine (engine) and LibraryService (library) environment objects.
// Playback is routed through the injected `onPlay` closure so online tracks
// can be handled by the host's OnlinePlaybackCoordinator — HomeView never
// calls engine.play directly. Artist taps go through `onArtist`.

import SwiftUI

// MARK: - Quick-link destinations
//
// Platform-agnostic enum the quick-link chips emit. The host (MainTabView on
// iOS, MacContentRouter on macOS) maps it onto its own navigation model.

public enum HomeQuickLink: Hashable {
    case songs, albums, artists, playlists
}

public struct HomeView: View {

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    /// Invoked when a quick-link chip is tapped. Host translates navigation.
    private let onQuickLink: (HomeQuickLink) -> Void

    /// Invoked to play a track in a given context. The host decides whether to
    /// route through the online coordinator (Discover tracks) or the offline
    /// engine — HomeView stays playback-agnostic. Defaults to a no-op so
    /// previews / compilation stay safe.
    private let onPlay: (_ track: Track, _ context: [Track]) -> Void

    /// Invoked when a recent-artist avatar is tapped. Defaults to a no-op; the
    /// host wires it to its artist destination (Mac) or leaves it inert (iOS).
    private let onArtist: (_ name: String) -> Void

    @State private var showStats = false

    /// Spotify-sourced artist profile images for "Recent artists", keyed by
    /// lowercased name. Discover-only artists have no library `Artist` row, so we
    /// fetch their photo from `deps.spotifyClient` and cache the bytes here.
    @State private var remoteArtistArtwork: [String: Data] = [:]

    public init(
        onQuickLink: @escaping (HomeQuickLink) -> Void = { _ in },
        onPlay: @escaping (_ track: Track, _ context: [Track]) -> Void = { _, _ in },
        onArtist: @escaping (_ name: String) -> Void = { _ in }
    ) {
        self.onQuickLink = onQuickLink
        self.onPlay = onPlay
        self.onArtist = onArtist
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

    /// Recently played, de-duplicated by stable key (see `deduped`). Online
    /// tracks get a fresh UUID per play, so without this the same song appears
    /// multiple times in the carousel.
    private var recentlyPlayed: [Track] {
        Array(deduped(engine.recentlyPlayed).prefix(12))
    }

    private var recentlyAdded: [Track] {
        deduped(
            library.tracks
                .sorted { $0.dateImported > $1.dateImported }
        )
        .prefix(12)
        .map { $0 }
    }

    private var favourites: [Track] {
        deduped(
            library.tracks.filter { library.isFavourited(trackID: $0.id) }
        )
        .prefix(12)
        .map { $0 }
    }

    /// "Made for you" — recommendations derived purely from local data (no
    /// network). We take the user's top artists from listening history and
    /// surface their library tracks the user *hasn't* played recently, falling
    /// back to favourites / most-imported so the row is never empty.
    private var recommendations: [Track] {
        let stats = deps.statsService.compute(period: .allTime)
        let recentKeys = Set(engine.recentlyPlayed.prefix(12).map(stableKey))

        // Tracks by the user's most-played artists, excluding very recent plays.
        let topArtistNames = stats.topArtists.map { $0.name }
        var picks: [Track] = []
        for name in topArtistNames {
            let byArtist = library.tracks
                .filter { $0.artistName.localizedCaseInsensitiveCompare(name) == .orderedSame }
                .filter { !recentKeys.contains(stableKey($0)) }
            picks.append(contentsOf: byArtist)
        }

        // Fall back to favourites, then most-recently imported, to fill out.
        if picks.count < 6 {
            picks.append(contentsOf: library.tracks.filter { library.isFavourited(trackID: $0.id) })
        }
        if picks.count < 6 {
            picks.append(contentsOf: library.tracks.sorted { $0.dateImported > $1.dateImported })
        }

        return Array(deduped(picks).prefix(12))
    }

    /// Circular artist row — distinct artists from recently-played tracks,
    /// matched to a library `Artist` (for artwork) where one exists.
    private var recentArtists: [HomeArtist] {
        var seen = Set<String>()
        var result: [HomeArtist] = []
        for track in engine.recentlyPlayed {
            let name = track.artistName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let artwork = library.artist(named: name)?.artworkData ?? remoteArtistArtwork[key]
            result.append(HomeArtist(name: name, artworkData: artwork))
            if result.count >= 12 { break }
        }
        return result
    }

    /// The featured hero card surfaces the single most recently played track —
    /// a big, tappable "pick up where you left off" entry point.
    private var featured: Track? { recentlyPlayed.first }

    private var isLibraryEmpty: Bool { library.tracks.isEmpty }

    // MARK: Stable de-dup
    //
    // Online tracks are minted with a fresh UUID `id` every play, so two plays
    // of the same song are *different* Track values that ForEach(id: \.id) would
    // render twice. The stable identity for an online track is its file hash
    // ("title|artist"); local tracks already have a stable `id`.

    private func stableKey(_ track: Track) -> String {
        track.file.fileHash.isEmpty ? track.id.uuidString : track.file.fileHash
    }

    /// Keep the first occurrence per stable key, preserving order.
    private func deduped(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for track in tracks where seen.insert(stableKey(track)).inserted {
            result.append(track)
        }
        return result
    }

    // MARK: Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                // Only show the empty state when there's truly nothing to surface
                // — no local library AND no played history. A Discover-only user
                // has an empty library but still has recently-played online tracks
                // to "pick up where you left off". The library-derived carousels
                // below each guard their own visibility, so they stay hidden.
                if isLibraryEmpty && recentlyPlayed.isEmpty {
                    emptyState
                } else {
                    if let featured {
                        heroCard(featured)
                    }

                    quickLinks

                    if !recentlyPlayed.isEmpty {
                        carousel(title: "Jump back in", tracks: recentlyPlayed)
                    }
                    if !recentArtists.isEmpty {
                        artistRow(title: "Recent artists", artists: recentArtists)
                    }
                    if !recommendations.isEmpty {
                        carousel(title: "Made for you", tracks: recommendations)
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

    // MARK: Hero / featured card
    //
    // A wide, full-width card that re-launches the most recent track. Larger
    // than the carousel cards so the home screen opens with a clear focal point.

    private func heroCard(_ track: Track) -> some View {
        Button {
            Haptics.play(.light)
            onPlay(track, recentlyPlayed)
        } label: {
            HStack(spacing: 14) {
                ArtworkThumbnail(
                    data: track.artworkData,
                    size: 88,
                    cornerRadius: 10,
                    placeholder: MixtapeIcons.track
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PICK UP WHERE YOU LEFT OFF")
                        .font(.mixCaptionBold)
                        .foregroundStyle(Color.mixPrimary)
                    Text(track.title)
                        .font(.mixTitle2)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: MixtapeIcons.play)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.mixPrimary, in: Circle())
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.mixSeparator, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    // Key by stable identity so any residual duplicates can't
                    // collapse together / re-render unexpectedly.
                    ForEach(tracks, id: \.self) { track in
                        HomeTrackCard(track: track) {
                            Haptics.play(.light)
                            onPlay(track, tracks)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Recent artists

    private func artistRow(title: String, artists: [HomeArtist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(artists) { artist in
                        HomeArtistAvatar(artist: artist) {
                            Haptics.play(.light)
                            onArtist(artist.name)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .task(id: artists.map(\.name).joined(separator: "|")) {
            await loadRemoteArtistImages(for: artists)
        }
    }

    /// Fetch Spotify profile images for any recent artist that doesn't already
    /// have artwork (i.e. Discover-only artists with no library `Artist` row),
    /// download the bytes, and cache them so the avatars fill in.
    private func loadRemoteArtistImages(for artists: [HomeArtist]) async {
        let missing = artists.filter { $0.artworkData == nil }.map(\.name)
        guard !missing.isEmpty else { return }
        let urls = await deps.spotifyClient.artistImages(for: missing)
        for (name, url) in urls {
            let key = name.lowercased()
            if remoteArtistArtwork[key] != nil { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                remoteArtistArtwork[key] = data
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
            message: "Tracks you add or play will appear here."
        )
        .padding(.vertical, 40)
    }
}

// MARK: - Recent artist model
//
// Lightweight value type for the circular artist row. Decoupled from the
// library `Artist` so artists that exist only in recently-played online tracks
// (no library record) can still appear, just without artwork.

private struct HomeArtist: Identifiable {
    var id: String { name.lowercased() }
    let name: String
    let artworkData: Data?
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

// MARK: - Artist Avatar

private struct HomeArtistAvatar: View {
    let artist: HomeArtist
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ArtworkThumbnail(
                    data: artist.artworkData,
                    size: 96,
                    cornerRadius: 48,            // fully circular
                    placeholder: MixtapeIcons.artist
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

                Text(artist.name)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 96)
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
