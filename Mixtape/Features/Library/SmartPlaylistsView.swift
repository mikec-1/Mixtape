// SmartPlaylistsView.swift
// Mixtape — Features/Library
//
// Lists the user's smart playlists + a "New Smart Playlist" entry. Tapping a
// playlist resolves it live and shows its tracks, which are playable through
// the shared PlaybackEngine.

import SwiftUI
import SwiftData

public struct SmartPlaylistsView: View {

    @EnvironmentObject private var deps: AppDependencies
    @StateObject private var service: SmartPlaylistService

    @State private var showEditor = false

    public init(deps: AppDependencies) {
        _service = StateObject(wrappedValue: SmartPlaylistService(
            context:  deps.modelContainer.mainContext,
            deviceID: AppDependencies.deviceID
        ))
    }

    public var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()

            if service.playlists.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(service.playlists) { playlist in
                        NavigationLink {
                            SmartPlaylistDetailView(playlist: playlist, service: service)
                                .environmentObject(deps)
                        } label: {
                            SmartPlaylistRow(playlist: playlist)
                        }
                        .listRowBackground(Color.mixBackground)
                        .listRowSeparatorTint(Color.mixSeparator)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                service.delete(id: playlist.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Smart Playlists")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: {
                    Image(systemName: "plus").foregroundStyle(Color.mixTextPrimary)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            SmartPlaylistEditorView(service: service)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No Smart Playlists")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Smart playlists update themselves from rules. Tap + to create one.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button { showEditor = true } label: {
                Label("New Smart Playlist", systemImage: "plus")
                    .font(.mixButton)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.mixPrimary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - Row

private struct SmartPlaylistRow: View {
    let playlist: SmartPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mixPrimary.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: playlist.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(playlist.rule.summary)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail (resolved tracks)

private struct SmartPlaylistDetailView: View {

    let playlist: SmartPlaylist
    @ObservedObject var service: SmartPlaylistService

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    private var tracks: [Track] {
        service.resolve(
            playlist,
            using: deps.libraryService,
            history: PlayHistoryRepository(context: deps.modelContainer.mainContext)
        )
    }

    var body: some View {
        let resolved = tracks
        ZStack {
            Color.mixBackground.ignoresSafeArea()
            if resolved.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: playlist.iconName)
                        .font(.system(size: 40))
                        .foregroundStyle(Color.mixTextTertiary)
                    Text("No matching tracks")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                }
            } else {
                List {
                    ForEach(resolved) { track in
                        Button {
                            Task { await engine.play(track: track, in: resolved) }
                        } label: {
                            TrackRowView(
                                track: track,
                                isCurrent: engine.queue.currentTrack?.id == track.id,
                                isPlaying: engine.state.isPlaying
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.mixBackground)
                        .listRowSeparatorTint(Color.mixSeparator)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }
}
