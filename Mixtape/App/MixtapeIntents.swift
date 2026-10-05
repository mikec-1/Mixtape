// Siri and Shortcuts intents.

import AppIntents

/// Intents can run with no window, so they go through `deps`.
enum MixtapeIntents {
    static weak var deps: AppDependencies?

    /// Widgets call this last so the reload shows the new state.
    @MainActor static func refreshWidgets() async {
        #if os(iOS)
        await deps?.nowPlayingSurfaces?.flush()
        #endif
    }

    /// A cold background launch hasn't read the library yet.
    static func library() async throws -> LibraryService {
        guard let library = deps?.libraryService else { throw MixtapeIntentError.notReady }
        if !library.hasLoaded { await library.loadForDisplay() }
        return library
    }

    static func playlists() async throws -> [PlaylistIntentItem] {
        try await library().playlists.map { PlaylistIntentItem(id: $0.id, name: $0.name) }
    }
}

nonisolated enum MixtapeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, gone
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Mixtape is still starting. Try again in a moment."
        case .gone:     "That playlist isn't in your library any more."
        }
    }
}

nonisolated struct PlaylistIntentItem: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Playlist" }
    static let defaultQuery = PlaylistQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct PlaylistQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [PlaylistIntentItem] {
        try await MixtapeIntents.playlists().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [PlaylistIntentItem] {
        try await MixtapeIntents.playlists().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [PlaylistIntentItem] {
        try await MixtapeIntents.playlists()
    }
}

/// Not `nonisolated` like its neighbours: `@Parameter` storage can't be.
struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play Playlist" }
    static var description: IntentDescription { "Plays one of your Mixtape playlists." }

    @Parameter(title: "Playlist") var playlist: PlaylistIntentItem

    /// Same as the header's Play button.
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = try await MixtapeIntents.library()
        guard let deps = MixtapeIntents.deps else { throw MixtapeIntentError.notReady }
        guard let list = library.playlist(id: playlist.id) else { throw MixtapeIntentError.gone }
        let tracks = (list.isAllSongs ? library.tracks : list.trackIDs.compactMap { library.displayTrack(id: $0) })
            .filter(\.canResolveAudio)
        let shuffles = ShufflePreferences.shared.shuffles(.playlist(list.id))
        deps.playbackEngine.queue.setShuffle(shuffles)
        guard let first = shuffles ? tracks.randomElement() : tracks.first else {
            return .result(dialog: "\(list.name) has no songs to play.")
        }
        await deps.playbackEngine.play(track: first, in: tracks, source: .playlist(id: list.id, name: list.name))
        return .result(dialog: "Playing \(list.name).")
    }
}

nonisolated struct LikeCurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource { "Like Current Song" }
    static var description: IntentDescription { "Adds the song that's playing to your Liked Songs." }

    /// Never an unlike: saying "like" twice shouldn't undo the first.
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = MixtapeIntents.deps?.playbackEngine, let track = engine.queue.currentTrack else {
            return .result(dialog: "Nothing is playing.")
        }
        if engine.isLiked?(track) == true {
            return .result(dialog: "\(track.displayTitle) is already in your Liked Songs.")
        }
        await engine.onRemoteLike?(track)
        engine.syncRemoteCommandState()
        return .result(dialog: "Added \(track.displayTitle) to your Liked Songs.")
    }
}

nonisolated struct MixtapeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play \(\.$playlist) on \(.applicationName)",
            "Play my \(\.$playlist) in \(.applicationName)",
            "Play \(.applicationName)",
            // Phrases avoid starting with "Play" so Siri's music domain doesn't claim them.
            "\(.applicationName) \(\.$playlist)",
            "Open \(\.$playlist) in \(.applicationName)",
            "Put on \(\.$playlist) in \(.applicationName)",
            "Start \(\.$playlist) in \(.applicationName)",
            "Start my \(\.$playlist) playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: LikeCurrentSongIntent(), phrases: [
            "Like this song in \(.applicationName)",
            "Like this song on \(.applicationName)",
        ], shortTitle: "Like Song", systemImageName: "heart")
    }
}
