// QueueView.swift
// Mixtape — Features/Queue
//
// Replaces the Now Playing tab.
// Two segments:
//   Queue          — current track + upcoming tracks from QueueService
//   Recently Played — tracks played this session (PlaybackEngine.recentlyPlayed)

import SwiftUI

public struct QueueView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies

    private enum Segment: String, CaseIterable {
        case queue          = "Queue"
        case recentlyPlayed = "Recently Played"
    }

    @State private var segment: Segment = .queue

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Segmented picker
                    Picker("", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().background(Color.mixSeparator)

                    // Content
                    switch segment {
                    case .queue:          queueContent
                    case .recentlyPlayed: recentContent
                    }
                }
            }
            .navigationTitle("Queue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
        }
    }

    // MARK: - Queue Section

    @ViewBuilder
    private var queueContent: some View {
        let current  = engine.queue.currentTrack
        let allTracks = engine.queue.queue
        let idx       = engine.queue.currentIndex

        if current == nil {
            emptyState(
                icon:     "music.note.list",
                title:    "Nothing Playing",
                subtitle: "Start playing a track from your library to see the queue here."
            )
        } else {
            List {
                // Now Playing
                if let current {
                    Section(header: sectionHeader("Now Playing")) {
                        TrackRowView(
                            track:          current,
                            isCurrent:      true,
                            isPlaying:      engine.state.isPlaying,
                            downloadStatus: deps.downloadManager.status(for: current.id)
                        )
                        .listRowBackground(Color.mixSurface.opacity(0.6))
                        .contextMenu {
                            Button("Play Now") {
                                Task { await engine.play(track: current, in: allTracks) }
                            }
                            Button("Play Next") { engine.queue.insertNext(current) }
                            Button("Add to Queue") { engine.queue.append(current) }
                            Divider()
                            let favoured = deps.libraryService.isFavourited(trackID: current.id)
                            Button(favoured ? "Remove from Favourites" : "Add to Favourites", systemImage: favoured ? "heart.fill" : "heart") {
                                deps.libraryService.toggleFavourite(trackID: current.id)
                            }
                            if deps.downloadManager.status(for: current.id) != .notDownloaded {
                                Divider()
                                Button("Remove Download", systemImage: "xmark.circle") {
                                    deps.downloadManager.removeDownload(for: current.id)
                                }
                            }
                        }
                    }
                }

                // Up Next
                let upcoming: [Track] = idx + 1 < allTracks.count
                    ? Array(allTracks[(idx + 1)...])
                    : []

                if !upcoming.isEmpty {
                    Section(header: sectionHeader("Up Next")) {
                        ForEach(upcoming) { track in
                            TrackRowView(
                                track:          track,
                                downloadStatus: deps.downloadManager.status(for: track.id)
                            )
                            .listRowBackground(Color.mixBackground)
                            .onTapGesture {
                                Task { await engine.play(track: track, in: allTracks) }
                            }
                            .contextMenu {
                                Button("Play Now") {
                                    Task { await engine.play(track: track, in: allTracks) }
                                }
                                Button("Play Next") { engine.queue.insertNext(track) }
                                Button("Add to Queue") { engine.queue.append(track) }
                                Divider()
                                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                                Button(favoured ? "Remove from Favourites" : "Add to Favourites", systemImage: favoured ? "heart.fill" : "heart") {
                                    deps.libraryService.toggleFavourite(trackID: track.id)
                                }
                                if deps.downloadManager.status(for: track.id) != .notDownloaded {
                                    Divider()
                                    Button("Remove Download", systemImage: "xmark.circle") {
                                        deps.downloadManager.removeDownload(for: track.id)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("No more tracks in queue.")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextTertiary)
                            .listRowBackground(Color.mixBackground)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Recently Played Section

    @ViewBuilder
    private var recentContent: some View {
        if engine.recentlyPlayed.isEmpty {
            emptyState(
                icon:     "clock.arrow.circlepath",
                title:    "No History Yet",
                subtitle: "Tracks you play will appear here."
            )
        } else {
            // Use offset as the list identity so the same track appearing at
            // multiple positions (played more than once) doesn't produce duplicate IDs.
            List(Array(engine.recentlyPlayed.enumerated()), id: \.offset) { _, track in
                TrackRowView(
                    track:          track,
                    isCurrent:      engine.queue.currentTrack?.id == track.id,
                    isPlaying:      engine.state.isPlaying,
                    downloadStatus: deps.downloadManager.status(for: track.id)
                )
                .listRowBackground(Color.mixBackground)
                .listRowSeparatorTint(Color.mixSeparator)
                .onTapGesture {
                    // Play in the full library context so the queue continues normally.
                    // Fall back to single-track only if the library doesn't have it yet.
                    let library = deps.libraryService.tracks
                    let source  = library.contains(where: { $0.id == track.id }) ? library : [track]
                    Task { await engine.play(track: track, in: source) }
                }
                .contextMenu {
                    Button("Play Now") {
                        let library = deps.libraryService.tracks
                        let source  = library.contains(where: { $0.id == track.id }) ? library : [track]
                        Task { await engine.play(track: track, in: source) }
                    }
                    Button("Play Next") { engine.queue.insertNext(track) }
                    Button("Add to Queue") { engine.queue.append(track) }
                    Divider()
                    let favoured = deps.libraryService.isFavourited(trackID: track.id)
                    Button(favoured ? "Remove from Favourites" : "Add to Favourites", systemImage: favoured ? "heart.fill" : "heart") {
                        deps.libraryService.toggleFavourite(trackID: track.id)
                    }
                    if deps.downloadManager.status(for: track.id) != .notDownloaded {
                        Divider()
                        Button("Remove Download", systemImage: "xmark.circle") {
                            deps.downloadManager.removeDownload(for: track.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .textCase(nil)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(subtitle)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    QueueView()
        .environmentObject(PlaybackEngine(
            queue:       QueueService(),
            fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
            equalizer:   AudioEqualizer()
        ))
        .environmentObject(AppDependencies())
}
