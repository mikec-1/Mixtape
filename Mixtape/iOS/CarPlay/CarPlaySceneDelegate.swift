// CarPlay: Playlists and Recently Played. Now Playing is the system template, fed by
// MPNowPlayingInfoCenter. Simulator only: a device build needs the carplay-audio entitlement.

#if os(iOS)
import CarPlay
import Combine

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?
    private let playlists = CPListTemplate(title: "Playlists", sections: [])
    private let recents = CPListTemplate(title: "Recently Played", sections: [])
    private var cancellables = Set<AnyCancellable>()

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        playlists.tabImage = UIImage(systemName: "music.note.list")
        recents.tabImage = UIImage(systemName: "clock")
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [playlists, recents]),
                                            animated: false, completion: nil)
        guard let deps = MixtapeIntents.deps else { return }
        deps.libraryService.$playlists
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.showPlaylists($0) }
            .store(in: &cancellables)
        deps.playbackEngine.$recentlyPlayed
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.showRecents($0) }
            .store(in: &cancellables)
        if !deps.libraryService.hasLoaded { Task { await deps.libraryService.loadForDisplay() } }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        cancellables.removeAll()
        interface = nil
    }

    private func showPlaylists(_ lists: [Playlist]) {
        let library = MixtapeIntents.deps?.libraryService
        let items = lists.map { list in
            let art = list.displayArtwork
                ?? library?.coverRefs(forPlaylistID: list.id, candidates: 1).first.flatMap { ArtworkProvider.shared.data(for: $0) }
            let item = CPListItem(text: list.name, detailText: nil, image: Self.image(art, fallback: "music.note.list"))
            item.handler = { [weak self] _, done in
                Task {
                    let intent = PlayPlaylistIntent()
                    intent.playlist = PlaylistIntentItem(id: list.id, name: list.name)
                    _ = try? await intent.perform()
                    self?.showNowPlaying()
                    done()
                }
            }
            return item
        }
        playlists.updateSections([CPListSection(items: items)])
    }

    private func showRecents(_ tracks: [Track]) {
        let recent = Array(tracks.prefix(25))
        let items = recent.map { track in
            let item = CPListItem(text: track.displayTitle, detailText: track.displayArtistName,
                                  image: Self.image(track.displayArtwork, fallback: "music.note"))
            item.handler = { [weak self] _, done in
                Task {
                    await MixtapeIntents.deps?.playbackEngine.play(track: track, in: recent,
                                                                   source: .named("Recently Played"))
                    self?.showNowPlaying()
                    done()
                }
            }
            return item
        }
        recents.updateSections([CPListSection(items: items)])
    }

    private func showNowPlaying() {
        guard let interface, interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private static func image(_ data: Data?, fallback: String) -> UIImage? {
        data.flatMap { ImageDownsampler.downsampledJPEG(from: $0, maxDimension: 120) }.flatMap(UIImage.init(data:))
            ?? UIImage(systemName: fallback)
    }
}
#endif
