// "Copy Link" and "Share" for anything with a mixtaped.tech link. Flat, not
// a submenu. "Share..." opens `MixShareSheet`, not the system sheet.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What a Share hands out: the link, and enough to draw a preview card of it.
struct ShareItem {
    enum Artwork {
        case none
        /// Bytes the caller already holds, else the store row.
        case stored(Data?, ArtworkRef?)
        case remote(URL?)
        /// A library playlist's cover, including the one it borrows from its songs.
        case playlist(UUID)
    }

    let url: URL
    /// "Song", "Album", "Artist", "Playlist".
    let noun: String
    let title: String
    let subtitle: String
    var artwork: Artwork = .none
    /// Artists are drawn in a circle, as everywhere else in the app.
    var isRound = false
    /// Songs, so a card sent in Messages can play.
    var track: OnlineTrack? = nil
    /// A finished picture that is the share itself. It goes to people as a photo, not a link card.
    var image: Data? = nil
    /// Runs as the link goes out, for a link that only opens for others once it's public.
    var beforeLink: (() -> Void)? = nil

    static func track(_ t: Track) -> ShareItem {
        ShareItem(url: MixtapeLink.track(t), noun: "Song", title: t.displayTitle, subtitle: t.displayArtistName,
                  artwork: .stored(t.artworkData, .track(t.id)),
                  track: OnlineTrack(title: ImportService.bareTitle(t.title), artistName: t.artistName,
                                     albumTitle: t.albumTitle, duration: t.duration))
    }

    static func track(_ t: OnlineTrack) -> ShareItem {
        ShareItem(url: MixtapeLink.track(t), noun: "Song", title: t.title, subtitle: t.displayArtistName,
                  artwork: .remote(t.artworkURL), track: t)
    }

    static func album(_ a: Album) -> ShareItem {
        ShareItem(url: MixtapeLink.album(title: a.title, artist: a.artistName), noun: "Album",
                  title: a.title, subtitle: a.artistName, artwork: .stored(a.artworkData, .album(a.id)))
    }

    static func album(_ a: OnlineAlbum) -> ShareItem {
        ShareItem(url: MixtapeLink.album(a), noun: "Album", title: a.title, subtitle: a.artistName,
                  artwork: .remote(a.coverURL))
    }

    static func artist(_ a: Artist) -> ShareItem {
        artist(name: a.name, artwork: .stored(a.artworkData, .artist(a.id)))
    }

    static func artist(_ a: OnlineArtist) -> ShareItem {
        ShareItem(url: MixtapeLink.artist(id: a.id, name: a.name), noun: "Artist", title: a.name,
                  subtitle: "Artist", artwork: .remote(a.imageURL), isRound: true)
    }

    static func artist(name: String, artwork: Artwork) -> ShareItem {
        ShareItem(url: MixtapeLink.artist(id: nil, name: name), noun: "Artist", title: name,
                  subtitle: "Artist", artwork: artwork, isRound: true)
    }

    static func playlist(_ s: PublicPlaylistSummary) -> ShareItem {
        ShareItem(url: MixtapeLink.playlist(s.id), noun: "Playlist", title: s.name,
                  subtitle: "Playlist", artwork: .remote(s.artworkURL))
    }

    static func playlist(_ p: Playlist, sharedID: UUID) -> ShareItem {
        ShareItem(url: MixtapeLink.playlist(sharedID), noun: "Playlist", title: p.name,
                  subtitle: "Playlist", artwork: .playlist(p.id))
    }

    /// The recap card as a picture; the link opens the recap on the site.
    static func recap(_ png: Data, title: String, username: String, shareID: String?) -> ShareItem {
        ShareItem(url: shareID.map(MixtapeLink.recap) ?? MixtapeLink.web("@\(username)"),
                  noun: "Recap", title: title, subtitle: "@\(username)", image: png)
    }

    /// The cover picked for the dub, which may not be the playlist's.
    static func dub(_ p: Playlist, sharedID: UUID, for name: String, artwork: Data?) -> ShareItem {
        ShareItem(url: MixtapeLink.playlist(sharedID), noun: "Dub", title: p.name,
                  subtitle: "For \(name)", artwork: .stored(artwork, nil))
    }
}

/// Links known up front: songs, albums, artists.
struct ShareMenuItems: View {
    let item: ShareItem

    init(_ item: ShareItem) { self.item = item }

    @Environment(AppDependencies.self) private var deps

    var body: some View {
        Button {
            copyToClipboard(item.url.absoluteString)
            deps.showToast(ShareSheet.copiedMessage)
        } label: {
            Label("Copy \(item.noun) Link", systemImage: "link")
        }
        // iOS sends from the share sheet's own row.
        #if os(macOS)
        if deps.authService.currentUser != nil {
            Button { ShareSheet.sendTo(item, deps: deps) } label: {
                Label(ShareSheet.sendTitle, systemImage: "paperplane")
            }
        }
        #endif
        // iOS only; on macOS copying the link is enough.
        #if os(iOS)
        Button { ShareSheet.present(item, deps: deps) } label: {
            Label(ShareSheet.title, systemImage: MixtapeIcons.share)
        }
        #endif
    }
}

/// A playlist's link exists only once shared, so both items work on press.
struct PlaylistShareMenuItems: View {
    let playlist: Playlist

    @Environment(AppDependencies.self) private var deps

    var body: some View {
        Group {
            Button { share(.copy) } label: {
                Label("Copy Playlist Link", systemImage: "link")
            }
            #if os(iOS)
            Button { share(.sheet) } label: {
                Label(ShareSheet.title, systemImage: MixtapeIcons.share)
            }
            #else
            Button { share(.send) } label: {
                Label(ShareSheet.sendTitle, systemImage: "paperplane")
            }
            #endif
        }
        // A link is a row in someone's account; there is no anonymous one.
        .disabled(deps.authService.currentUser == nil || playlist.isSystem)
    }

    private enum Action { case copy, sheet, send }

    private func share(_ action: Action) {
        let live = deps.libraryService.playlist(id: playlist.id) ?? playlist
        let tracks = live.trackIDs.compactMap { deps.libraryService.track(id: $0) }
        Task {
            do {
                let id = try await PlaylistSharingService.shared.linkShareID(
                    playlist: live, tracks: tracks, deviceID: AppDependencies.deviceID)
                let item = ShareItem.playlist(live, sharedID: id)
                switch action {
                case .copy:
                    copyToClipboard(item.url.absoluteString)
                    deps.showToast(ShareSheet.copiedMessage)
                case .sheet:
                    ShareSheet.present(item, deps: deps)
                case .send:
                    ShareSheet.sendTo(item, deps: deps)
                }
            } catch PlaylistSharingService.SharingError.notOwner {
                deps.showToast(.failed("Only the owner can share a link to this playlist"))
            } catch {
                deps.showToast(.failed("Couldn\u{2019}t make a link. Try again.", error))
            }
        }
    }
}

/// Share sheet for when the link arrives after the menu is gone.
enum ShareSheet {
    #if os(macOS)
    static let title = "Share"
    #else
    static let title = "Share\u{2026}"
    #endif

    static var copiedMessage: Toast { .done("Link copied to clipboard") }
    static let sendTitle = "Send to\u{2026}"

    /// A people picker over whatever is showing; the menu that asked is already gone.
    @MainActor
    static func sendTo(_ item: ShareItem, deps: AppDependencies) {
        #if os(iOS)
        guard let top = topViewController() else { return }
        let host = UIHostingController(rootView: SendToSheet(item: item, close: {}).environment(deps))
        host.rootView = SendToSheet(item: item) { [weak host] in host?.dismiss(animated: true) }.environment(deps)
        host.view.backgroundColor = UIColor(Color.mixBackground)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        if let coordinator = top.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in top.present(host, animated: true) }
        } else {
            top.present(host, animated: true)
        }
        #elseif os(macOS)
        guard let parent = NSApp.keyWindow?.contentViewController else { return }
        let host = NSHostingController(rootView: SendToSheet(item: item, close: {}).environment(deps))
        host.rootView = SendToSheet(item: item) { [weak host] in host?.dismiss(nil) }.environment(deps)
        parent.presentAsSheet(host)
        #endif
    }

    @MainActor
    static func present(_ item: ShareItem, deps: AppDependencies) {
        present([ShareChoice(label: item.noun, item: item)], deps: deps)
    }

    /// Several things to pick between, like a recap's slide, card and link. `dismissed` runs as it goes.
    @MainActor
    static func present(_ choices: [ShareChoice], deps: AppDependencies, dismissed: (() -> Void)? = nil) {
        guard !choices.isEmpty else { return }
        #if os(iOS)
        guard let top = topViewController() else { return }
        let host = UIHostingController(rootView: MixShareSheet(choices: choices, deps: deps, close: {}))
        host.rootView = MixShareSheet(choices: choices, deps: deps, dismissed: dismissed) { [weak host] in
            host?.dismiss(animated: true)
        }
        host.view.backgroundColor = UIColor(Color.mixBackground)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        // A context menu is still animating away; presenting mid-transition is dropped.
        if let coordinator = top.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in top.present(host, animated: true) }
        } else {
            top.present(host, animated: true)
        }
        #elseif os(macOS)
        guard let parent = NSApp.keyWindow?.contentViewController else { return }
        let host = NSHostingController(rootView: MixShareSheet(choices: choices, deps: deps, close: {}))
        host.rootView = MixShareSheet(choices: choices, deps: deps, dismissed: dismissed) { [weak host] in host?.dismiss(nil) }
        parent.presentAsSheet(host)
        #endif
    }

    #if os(iOS)
    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}

/// Share button beside Play. iOS: opens the sheet. macOS: the same two items.
struct ShareHeroButton: View {
    let item: ShareItem

    init(_ item: ShareItem) { self.item = item }

    #if os(iOS)
    @Environment(AppDependencies.self) private var deps
    #endif

    var body: some View {
        #if os(iOS)
        Button { ShareSheet.present(item, deps: deps) } label: {
            HeroCircleLabel(systemImage: MixtapeIcons.share)
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .accessibilityLabel("Share")
        #else
        Menu { ShareMenuItems(item) } label: {
            HeroCircleLabel(systemImage: MixtapeIcons.share)
        }
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        .frame(width: 40, height: 40)
        .help("Share this \(item.noun.lowercased())")
        .accessibilityLabel("Share")
        #endif
    }
}
