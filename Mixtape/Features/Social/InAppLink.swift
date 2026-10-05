// mixtaped.tech links opened inside the app: playlists, jams, invites, recaps,
// crates and posts. Only pages the app doesn't have go to the browser.

import Foundation

@MainActor
enum InAppLink {
    enum Target {
        case playlist(Playlist)
        case page(PublicPlaylistSummary)
        case crate(UUID)
        /// A community post's share code.
        case post(String)
        /// Handled here (a jam joined, a recap opened).
        case done
        /// The app's kind of link, but this one is private or gone.
        case unavailable
    }

    /// Nil when the app has no page for the link, so the browser should have it.
    static func open(_ url: URL, deps: AppDependencies) async -> Target? {
        if let code = RootView.inviteCode(from: url, kind: "jam") {
            await deps.jam.join(code: code)
            return .done
        }
        if let code = RootView.inviteCode(from: url, kind: "blend") {
            await deps.blends.join(code: code)
            return .done
        }
        if let code = RootView.inviteCode(from: url) {
            guard let joined = try? await PlaylistSharingService.shared
                .redeemInvite(code: code, libraryService: deps.libraryService) else { return .unavailable }
            try? await deps.syncService.sync()
            return deps.libraryService.playlist(id: joined.localPlaylistID).map { .playlist($0) } ?? .unavailable
        }
        guard url.host?.hasSuffix("mixtaped.tech") != false else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch parts.first {
        case "playlist", "p", "playlists":
            let raw = parts.count > 1 ? parts[1] : query.first { $0.name == "id" }?.value
            guard let id = raw.flatMap(UUID.init(uuidString:)) else { return .unavailable }
            return await playlist(id, deps: deps)
        case "recap":
            guard parts.count > 1, let (recap, owner) = await deps.recap.recap(shareID: parts[1]) else { return .unavailable }
            let me = deps.authService.currentUser?.id
            let profile = owner == me ? nil : try? await deps.authService.fetchProfile(id: owner)
            deps.recap.open(recap, owner: profile)
            return .done
        case "post":
            guard parts.count > 1, CommunityService.isCode(parts[1]) else { return .unavailable }
            return .post(parts[1])
        case "crate":
            return crate(query.first { $0.name == "d" }?.value).map { .crate($0) } ?? .unavailable
        default:
            return nil
        }
    }

    static func playlist(_ sharedID: UUID, deps: AppDependencies) async -> Target {
        switch await PlaylistSharingService.shared.inAppTarget(sharedPlaylistID: sharedID,
                                                               libraryService: deps.libraryService) {
        case .library(let p): return .playlist(p)
        case .page(let s): return .page(s)
        case nil: return .unavailable
        }
    }

    /// Saves a sent crate to yours, or finds the copy already saved. See `MixtapeLink.crate`.
    private static func crate(_ d: String?) -> UUID? {
        struct Payload: Decodable { let n: String; let i: [[String]] }
        guard var b64 = d?.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") else { return nil }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let items: [CrateItem] = payload.i.compactMap { i in
            switch (i.first, i.count) {
            // ponytail: playlists come along only when this device has a copy; saving the rest needs a public-save pass.
            case ("p", 2): UUID(uuidString: i[1]).flatMap(PlaylistSharingService.shared.localPlaylistID).map(CrateItem.playlist)
            case ("a", 3): .album(title: i[1], artist: i[2])
            case ("r", 2): .artist(i[1])
            default: nil
            }
        }
        return CrateService.shared.adopt(named: payload.n, items: items).id
    }
}
