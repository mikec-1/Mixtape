// The top-bar inbox: invites, joins, saves, dubs, community activity and system notices, newest first.
// Rows come from the my_notifications RPC. Realtime only pokes; every change re-reads page 1.
// Same rules as mixtape-web/src/lib/inbox.ts.

import Combine
import Foundation
import os
import Supabase
import Observation

@Observable
@MainActor
public final class InboxService {

    public static let shared = InboxService()

    private init() {}

    private var client: SupabaseClient { SupabaseConfig.client }

    public struct Notice: Decodable, Identifiable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case invite, joined, dub, saved, system, follow
            case postLike = "post_like", postRepost = "post_repost"
            case postComment = "post_comment", commentReply = "comment_reply"

            /// A kind this build doesn't know yet shows as a plain notice instead of failing the page.
            public init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
            }
        }

        public let id: UUID
        public let kind: Kind
        /// shared_playlists.id, or posts.id for the post kinds. Nil for system and follow.
        public let subjectID: UUID?
        public let title: String?
        public let body: String?
        public let link: String?
        public let createdAt: Date
        public var readAt: Date?
        public let actorID: UUID?
        public let actorUsername: String?
        public let actorDisplayName: String?
        public let actorAvatarURL: String?
        public let subjectOwnerID: UUID?
        /// Path in the public playlist-covers bucket, or post-artwork for the post kinds.
        public let subjectArtwork: String?
        public let invitePending: Bool

        enum CodingKeys: String, CodingKey {
            case id, kind, title, body, link
            case subjectID = "subject_id"
            case createdAt = "created_at"
            case readAt = "read_at"
            case actorID = "actor_id"
            case actorUsername = "actor_username"
            case actorDisplayName = "actor_display_name"
            case actorAvatarURL = "actor_avatar_url"
            case subjectOwnerID = "subject_owner_id"
            case subjectArtwork = "subject_artwork"
            case invitePending = "invite_pending"
        }

        public var isPost: Bool { [.postLike, .postRepost, .postComment, .commentReply].contains(kind) }

        public var artworkURL: URL? {
            guard let subjectArtwork else { return nil }
            return isPost ? CommunityService.artworkURL(subjectArtwork) : PlaylistSharingService.coverURL(path: subjectArtwork)
        }

        /// The person who did it, for a follow row.
        public var actor: UserProfile? {
            guard let actorID, let actorUsername else { return nil }
            return UserProfile(id: actorID, username: actorUsername, displayName: actorDisplayName,
                               avatarURL: actorAvatarURL.flatMap(URL.init(string:)))
        }

        /// The line as bold, plain, bold runs, so banners and rows say the same thing.
        public var phrase: (who: String, verb: String, what: String) {
            let who = actorDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? actorUsername ?? "Someone"
            let what = title ?? (isPost ? "your post" : "a playlist")
            switch kind {
            case .invite: return (who, " invited you to ", what)
            case .joined: return (who, " joined ", what)
            case .saved:  return (who, " saved ", what)
            case .dub:    return (who, " made you a dub: ", what)
            case .postLike:     return (who, " liked ", what)
            case .postRepost:   return (who, " reposted ", what)
            case .postComment:  return (who, " commented on ", what)
            case .commentReply: return (who, " replied to your comment on ", what)
            case .follow:       return (who, " started following you", "")
            case .system: return (title ?? "Mixtape", "", "")
            }
        }

        public var sentence: String {
            let p = phrase
            return p.who + p.verb + p.what
        }
    }

    private static let pageSize = 50

    public private(set) var rows: [Notice] = [] { didSet { rowsSubject.send(rows) } }
    /// `$rows` for Combine users; sent after the set.
    public var rowsPublisher: AnyPublisher<[Notice], Never> { rowsSubject.prepend(rows).eraseToAnyPublisher() }
    @ObservationIgnored private let rowsSubject = PassthroughSubject<[Notice], Never>()
    public private(set) var loaded = false
    @ObservationIgnored public private(set) var hasMore = false
    /// Set while the inbox is on screen, so new rows are read as they arrive.
    @ObservationIgnored public var isOpen = false {
        didSet { if !isOpen { dots = [] } }
    }
    /// Rows the open inbox marked read. Their dots stay until it closes.
    public private(set) var dots: Set<UUID> = []
    /// Foreground arrivals toast instead of bannering. Wired by AppDependencies.
    @ObservationIgnored public var onToast: ((String) -> Void)?

    public var unreadCount: Int { rows.lazy.filter { $0.readAt == nil }.count }

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var pokeTask: Task<Void, Never>?

    // MARK: Reading

    public func refresh() async {
        let user = try? await client.auth.session.user.id
        if user != owner {
            owner = user
            rows = []
            loaded = false
            hasMore = false
        }
        guard let user, let page = await fetch(before: nil), owner == user else { return }

        // Keep older pages already scrolled into, so a poke doesn't snap the list back to 50.
        let full = page.count == Self.pageSize
        let kept = full ? rows.filter { $0.createdAt < page[page.count - 1].createdAt } : []
        rows = page + kept
        if kept.isEmpty { hasMore = full }
        loaded = true

        let foreground = AppVisibility.shared.isFrontmost
        let fresh = await InviteNotifier.shared.announce(page, suppressBanner: foreground)
        if isOpen {
            await markAllRead()
        } else if foreground, !fresh.isEmpty {
            onToast?(fresh.count == 1 ? fresh[0].sentence : "You have \(fresh.count) new notifications")
        }
    }

    public func loadMore() async {
        guard hasMore, !loadingMore, let last = rows.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = await fetch(before: last.createdAt) else { return }
        // ponytail: created_at-only cursor, rows sharing a millisecond can be skipped. Add an id tiebreak if it bites.
        let have = Set(rows.map(\.id))
        rows += page.filter { !have.contains($0.id) }
        hasMore = page.count == Self.pageSize
    }

    private func fetch(before: Date?) async -> [Notice]? {
        struct Params: Encodable {
            let p_before: Date?
            let p_limit: Int
        }
        do {
            return try await client
                .rpc("my_notifications", params: Params(p_before: before, p_limit: Self.pageSize))
                .execute()
                .value
        } catch {
            MixLog.sync.error("[Inbox] read failed: \(error)")
            return nil
        }
    }

    /// Opening the inbox reads everything. Local first so the badge clears at once.
    public func markAllRead() async {
        guard rows.contains(where: { $0.readAt == nil }) else { return }
        let now = Date()
        dots.formUnion(rows.lazy.filter { $0.readAt == nil }.map(\.id))
        for i in rows.indices where rows[i].readAt == nil { rows[i].readAt = now }
        do {
            try await client
                .from("notifications")
                .update(["read_at": now])
                .is("read_at", value: nil)
                .execute()
        } catch {
            MixLog.sync.error("[Inbox] mark read failed: \(error)")
        }
    }

    // MARK: Realtime

    /// Called from onRealtimeReady, so the socket already carries this user's token.
    /// INSERT and UPDATE only: DELETE events reach every subscriber.
    public func start(userID: UUID) {
        let previous = listenTask
        previous?.cancel()
        listenTask = Task { [weak self] in
            // The client keeps one channel per topic, so the old one has to be gone first.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let uid = userID.uuidString.lowercased()
            let channel = client.channel("inbox-\(uid)")
            let filter = RealtimePostgresFilter.eq("user_id", value: uid)
            let inserts = channel.postgresChange(InsertAction.self, table: "notifications", filter: filter)
            let updates = channel.postgresChange(UpdateAction.self, table: "notifications", filter: filter)
            await client.join(channel, label: "inbox")
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in inserts { await self.poke() } }
                group.addTask { for await _ in updates { await self.poke() } }
            }
            // The streams end on cancel.
            await client.removeChannel(channel)
        }
        Task { await refresh() }
    }

    public func stop() {
        // Kept, not cleared, so the next start() waits for its channel to go.
        listenTask?.cancel()
        pokeTask?.cancel()
        pokeTask = nil
        owner = nil
        rows = []
        loaded = false
        hasMore = false
        isOpen = false
    }

    /// Coalesces bursts: marking 20 rows read sends 20 UPDATE events.
    private func poke() {
        pokeTask?.cancel()
        pokeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Formatting

    /// Spotify's "4w": the largest whole unit.
    public nonisolated static func age(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let units: [(Double, String)] = [(31_536_000, "y"), (604_800, "w"), (86_400, "d"), (3_600, "h"), (60, "m")]
        for (size, label) in units where seconds >= size {
            return "\(Int(seconds / size))\(label)"
        }
        return "now"
    }
}
