// UserProfileView.swift
// Mixtape — Features/Social
//
// Read-only public profile for another user, opened from Find People. Shows
// avatar, handle, "member since", their published listening stats (top artists,
// top tracks, totals + streak) and their shared playlists.

import SwiftUI

public struct UserProfileView: View {

    @EnvironmentObject private var deps: AppDependencies

    private let profile: UserProfile

    @State private var stats: PublicProfileStats?
    @State private var playlists: [PublicPlaylistSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?

    public init(profile: UserProfile) {
        self.profile = profile
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Color.mixPrimary)
                        .padding(.top, 24)
                } else if let stats, stats.hasData {
                    totalsCard(stats)
                    if !stats.topArtists.isEmpty { topArtistsSection(stats.topArtists) }
                    if !stats.topTracks.isEmpty { topTracksSection(stats.topTracks) }
                } else {
                    quietState
                }

                if !playlists.isEmpty { playlistsSection }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(profile.username)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(url: profile.avatarURL, fallbackText: profile.username, size: 110)
                .padding(.top, 28)
            Text("@\(profile.username)")
                .font(.mixTitle)
                .foregroundStyle(Color.mixTextPrimary)
            if let joined = profile.createdAt {
                Text("Member since \(joined.formatted(.dateTime.month(.wide).year()))")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
    }

    private func totalsCard(_ s: PublicProfileStats) -> some View {
        HStack(spacing: 0) {
            stat("\(s.totalPlays)", "Plays")
            divider
            stat(minutesLabel(s.minutes), "Listened")
            divider
            stat("\(s.currentStreak)", s.currentStreak == 1 ? "Day streak" : "Day streak")
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(label)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Color.mixSeparator).frame(width: 0.5, height: 32)
    }

    private func topArtistsSection(_ artists: [PublicProfileStats.ArtistEntry]) -> some View {
        section("Top Artists") {
            ForEach(Array(artists.enumerated()), id: \.element.id) { idx, a in
                rankRow(rank: idx + 1, title: a.name, trailing: "\(a.plays)")
            }
        }
    }

    private func topTracksSection(_ tracks: [PublicProfileStats.TrackEntry]) -> some View {
        section("Top Tracks") {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                rankRow(rank: idx + 1, title: t.title, subtitle: t.artist, trailing: "\(t.plays)")
            }
        }
    }

    private var playlistsSection: some View {
        section("Shared Playlists") {
            ForEach(playlists) { p in
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(Color.mixPrimary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                            .font(.mixBodyBold)
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        if let d = p.description, !d.isEmpty {
                            Text(d).font(.mixCaption).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(p.trackCount)")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var quietState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(Color.mixTextTertiary)
            Text(loadError ?? "No public listening activity yet.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    // MARK: - Builders

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.mixSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func rankRow(rank: Int, title: String, subtitle: String? = nil, trailing: String) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixPrimary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.mixCaption).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(trailing)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.vertical, 8)
    }

    private func minutesLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            return "\(h)h"
        }
        return "\(minutes)m"
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let s = deps.profileStatsService.fetchStats(for: profile.id)
            async let p = deps.profileStatsService.fetchPublicPlaylists(for: profile.id)
            stats = try await s
            playlists = (try? await p) ?? []
        } catch {
            loadError = "Couldn't load this profile."
        }
    }
}
