// ShareMenuItems.swift
// Mixtape — SharedUI/Components
//
// "Copy Link" and "Share" for anything with a mixtaped.tech link, the same two
// items in every menu. Flat rather than a Share submenu: copying is what people
// reach for, and on macOS `ShareLink` already draws its own services submenu.
// On iOS "Share…" opens Mixtape's own sheet (`MixShareSheet`), not the system one.

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

    static func track(_ t: Track) -> ShareItem {
        ShareItem(url: MixtapeLink.track(t), noun: "Song", title: t.displayTitle, subtitle: t.displayArtistName,
                  artwork: .stored(t.artworkData, .track(t.id)))
    }

    static func track(_ t: OnlineTrack) -> ShareItem {
        ShareItem(url: MixtapeLink.track(t), noun: "Song", title: t.title, subtitle: t.displayArtistName,
                  artwork: .remote(t.artworkURL))
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
}

/// For links that are known up front — songs, albums, artists.
struct ShareMenuItems: View {
    let item: ShareItem

    init(_ item: ShareItem) { self.item = item }

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        Button {
            copyToClipboard(item.url.absoluteString)
            deps.showToast(ShareSheet.copiedMessage)
        } label: {
            Label("Copy \(item.noun) Link", systemImage: "link")
        }
        // iOS only. On macOS the system picker offers a list of services the
        // user doesn't have and drops a link into apps this one can't follow
        // up on — copying the link is the whole feature there.
        #if os(iOS)
        Button { ShareSheet.present(item, deps: deps) } label: {
            Label(ShareSheet.title, systemImage: MixtapeIcons.share)
        }
        #endif
    }
}

/// For a playlist, whose link only exists once its shared row does — so both
/// items do their work when pressed, never while the menu is being drawn.
struct PlaylistShareMenuItems: View {
    let playlist: Playlist

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        Group {
            Button { share(copy: true) } label: {
                Label("Copy Playlist Link", systemImage: "link")
            }
            #if os(iOS)
            Button { share(copy: false) } label: {
                Label(ShareSheet.title, systemImage: MixtapeIcons.share)
            }
            #endif
        }
        // A link is a row in someone's account; there is no anonymous one.
        .disabled(deps.authService.currentUser == nil || playlist.isSystem)
    }

    private func share(copy: Bool) {
        let live = deps.libraryService.playlist(id: playlist.id) ?? playlist
        let tracks = live.trackIDs.compactMap { deps.libraryService.track(id: $0) }
        Task {
            do {
                let id = try await PlaylistSharingService.shared.linkShareID(
                    playlist: live, tracks: tracks, deviceID: AppDependencies.deviceID)
                let item = ShareItem.playlist(live, sharedID: id)
                if copy {
                    copyToClipboard(item.url.absoluteString)
                    deps.showToast(ShareSheet.copiedMessage)
                } else {
                    ShareSheet.present(item, deps: deps)
                }
            } catch PlaylistSharingService.SharingError.notOwner {
                deps.showToast("Only the owner can share a link to this playlist")
            } catch {
                deps.showToast("Couldn\u{2019}t make a link. Try again.")
            }
        }
    }
}

/// The share sheet, for when the thing to share arrives after the menu that
/// asked for it has gone.
enum ShareSheet {
    #if os(macOS)
    static let title = "Share"
    #else
    static let title = "Share\u{2026}"
    #endif

    static let copiedMessage = "Link copied to clipboard"

    @MainActor
    static func present(_ item: ShareItem, deps: AppDependencies) {
        #if os(iOS)
        guard let top = topViewController() else { return }
        let host = UIHostingController(rootView: MixShareSheet(item: item, deps: deps, close: {}))
        host.rootView = MixShareSheet(item: item, deps: deps) { [weak host] in
            host?.dismiss(animated: true)
        }
        host.view.backgroundColor = UIColor(Color.mixBackground)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        // Pressed from a context menu, which is still animating away; presenting
        // mid-transition is silently dropped.
        if let coordinator = top.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in top.present(host, animated: true) }
        } else {
            top.present(host, animated: true)
        }
        #elseif os(macOS)
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [item.url])
            .show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
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

/// The share circle beside Play on a detail page. On iOS it opens the share
/// sheet straight away; on macOS it holds the same two items as a right-click.
struct ShareHeroButton: View {
    let item: ShareItem

    init(_ item: ShareItem) { self.item = item }

    #if os(iOS)
    @EnvironmentObject private var deps: AppDependencies
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
