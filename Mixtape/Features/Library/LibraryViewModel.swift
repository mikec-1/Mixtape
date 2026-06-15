// LibraryViewModel.swift
// Mixtape — Features/Library

import Foundation
import SwiftUI
import Combine

public enum LibrarySection: String, CaseIterable, Identifiable {
    case playlists  = "Playlists"
    case albums     = "Albums"
    case artists    = "Artists"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .playlists: return MixtapeIcons.playlist
        case .albums:    return MixtapeIcons.album
        case .artists:   return MixtapeIcons.artist
        }
    }
}

@MainActor
public final class LibraryViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var selectedSection: LibrarySection = .playlists

    @Published public private(set) var tracks:    [Track]    = []
    @Published public private(set) var albums:    [Album]    = []
    @Published public private(set) var artists:   [Artist]  = []
    @Published public private(set) var playlists: [Playlist] = []

    @Published public var showImportSheet = false

    // MARK: - Dependencies

    private let libraryService: LibraryService
    private var cancellables   = Set<AnyCancellable>()

    // MARK: - Init

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
        bindLibraryService()
    }

    // MARK: - Actions

    public func load() async {
        libraryService.refresh()
    }

    // MARK: - Private

    private func bindLibraryService() {
        libraryService.$tracks
            .receive(on: RunLoop.main)
            .assign(to: &$tracks)

        libraryService.$albums
            .receive(on: RunLoop.main)
            .assign(to: &$albums)

        libraryService.$artists
            .receive(on: RunLoop.main)
            .assign(to: &$artists)

        libraryService.$playlists
            .receive(on: RunLoop.main)
            .assign(to: &$playlists)
    }
}
