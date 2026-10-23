// 1:1 messages, behind the paper plane in the top bar. The server does the guarding (column grants, RLS,
// blocks both ways); this only reads and writes. Same rules as mixtape-web/src/lib/messages.ts.

import Combine
import Foundation
import ImageIO
import os
import Supabase
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
public final class MessagesService {

    public static let shared = MessagesService()

    private init() {}

    private var client: SupabaseClient { SupabaseConfig.client }

    /// One row per person from dm_threads(), newest first. People you've blocked are left out.
    public struct Thread: Decodable, Identifiable, Equatable, Sendable {
        public let otherID: UUID
        public let username: String?
        public let displayName: String?
        public let avatarURL: String?
        /// What was sent, from your side: the words, or "Sent you a photo" and so on.
        public let lastBody: String
        /// The message kind, or "unsent". Nil before the messages v2 migration.
        public let lastKind: String?
        public let lastAt: Date
        public let lastFromMe: Bool
        public var unread: Int

        public var id: UUID { otherID }

        /// "Mike: hey" for words, "Mike shared “Loyal” by Chris Brown" for the rest.
        public func said(by who: String) -> String {
            guard let kind = lastKind, kind != "text" else { return "\(who): \(lastBody)" }
            return "\(who) \(lastBody.prefix(1).lowercased())\(lastBody.dropFirst())"
        }

        public var profile: UserProfile {
            UserProfile(id: otherID,
                        username: username ?? "someone",
                        displayName: displayName,
                        avatarURL: avatarURL.flatMap(URL.init(string:)))
        }

        enum CodingKeys: String, CodingKey {
            case username
            case otherID = "other_id"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
            case lastBody = "last_body"
            case lastKind = "last_kind"
            case lastAt = "last_at"
            case lastFromMe = "last_from_me"
            case unread
        }
    }

    /// invite and dub are written by the server, the rest by clients.
    public enum Kind: String, Codable, Sendable { case text, image, sticker, share, invite, dub }

    /// Every kind's fields in one bag, as on the web. image: path, w, h. sticker: id. share: the card
    /// plus its url, and `path` when the cover couldn't be linked. invite and dub: sharedPlaylistID, name, artworkPath.
    public struct Payload: Codable, Equatable, Sendable {
        /// "song", "album", "artist" or "playlist".
        public var type: String?
        public var title: String?
        public var subtitle: String?
        public var artwork: String?
        public var round: Bool?
        /// Songs only, so the card can play.
        public var track: OnlineTrack?
        public var url: String?
        public var path: String?
        public var w: Double?
        public var h: Double?
        public var id: String?
        public var sharedPlaylistID: UUID?
        public var name: String?
        public var artworkPath: String?

        public init() {}

        enum CodingKeys: String, CodingKey {
            case type, title, subtitle, artwork, round, track, url, path, w, h, id, name
            case sharedPlaylistID = "shared_playlist_id"
            case artworkPath = "artwork_path"
        }
    }

    public struct Message: Codable, Identifiable, Equatable, Sendable {
        public let id: UUID
        public let senderID: UUID
        public let recipientID: UUID
        public var body: String
        public let createdAt: Date
        public var kind: Kind = .text
        public var payload: Payload? = nil
        public var readAt: Date? = nil
        public var editedAt: Date? = nil
        /// Kept as a row so the other side sees "unsent a message". Body and payload are gone.
        public var unsentAt: Date? = nil
        public var replyTo: UUID? = nil
        public var senderReaction: String? = nil
        public var recipientReaction: String? = nil

        enum CodingKeys: String, CodingKey {
            case id, body, kind, payload
            case senderID = "sender_id"
            case recipientID = "recipient_id"
            case createdAt = "created_at"
            case readAt = "read_at"
            case editedAt = "edited_at"
            case unsentAt = "unsent_at"
            case replyTo = "reply_to"
            case senderReaction = "sender_reaction"
            case recipientReaction = "recipient_reaction"
        }
    }

    public static let pageSize = 50

    public private(set) var threads: [Thread] = [] { didSet { threadsSubject.send(threads) } }
    /// `$threads` for Combine users; sent after the set.
    public var threadsPublisher: AnyPublisher<[Thread], Never> { threadsSubject.prepend(threads).eraseToAnyPublisher() }
    @ObservationIgnored private let threadsSubject = PassthroughSubject<[Thread], Never>()
    public private(set) var loaded = false
    /// Every message row realtime delivers, sent or received. An open thread picks out its own.
    public let incoming = PassthroughSubject<Message, Never>()
    /// Rows changed after they arrived: read, edited, unsent or reacted to.
    public let updated = PassthroughSubject<Message, Never>()
    /// The thread on screen, so its arrivals neither toast nor banner.
    @ObservationIgnored public var viewing: UUID?

    public var unreadCount: Int { threads.reduce(0) { $0 + $1.unread } }

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var pokeTask: Task<Void, Never>?

    // MARK: Reading

    public func refresh() async {
        let user = try? await client.auth.session.user.id
        if user != owner {
            owner = user
            threads = []
            loaded = false
        }
        guard let user else { return }
        do {
            let fresh: [Thread] = try await client.rpc("dm_threads").execute().value
            guard owner == user else { return }
            threads = fresh
            loaded = true
        } catch {
            MixLog.sync.error("[Messages] threads failed: \(error)")
            return
        }

        let foreground = AppVisibility.shared.isFrontmost
        let unseen = await InviteNotifier.shared.announceMessages(threads, suppressBanner: foreground)
            .filter { $0.otherID != viewing }
        if foreground, !unseen.isEmpty {
            onToast?(unseen.count == 1
                     ? unseen[0].said(by: unseen[0].profile.name)
                     : "You have \(unseen.count) new messages")
        }
    }

    /// Foreground arrivals toast instead of bannering. Wired by AppDependencies.
    @ObservationIgnored public var onToast: ((String) -> Void)?

    /// Newest first. RLS only returns rows you're in and nobody messages themselves,
    /// so "they sent it or received it" is exactly this thread.
    public func messages(with other: UUID, before: Date?) async throws -> [Message] {
        let id = other.uuidString.lowercased()
        var query = client
            .from("messages")
            .select("*")
            .or("sender_id.eq.\(id),recipient_id.eq.\(id)")
        // ponytail: created_at-only cursor like the inbox, rows sharing a millisecond can be skipped.
        if let before { query = query.lt("created_at", value: before) }
        return try await query
            .order("created_at", ascending: false)
            .limit(Self.pageSize)
            .execute()
            .value
    }

    /// The id is the client's, so the optimistic bubble and the realtime echo are the same row.
    public func send(id: UUID, to other: UUID, body: String = "", kind: Kind = .text, payload: Payload? = nil,
                     replyTo: UUID? = nil) async throws {
        struct Row: Encodable {
            let id: UUID
            let recipient_id: UUID
            let body: String
            let kind: Kind?
            let payload: Payload?
            let reply_to: UUID?
        }
        // Plain text leaves the new columns out, so it still sends before the attachments migration.
        let row = Row(id: id, recipient_id: other, body: body,
                      kind: kind == .text ? nil : kind, payload: kind == .text ? nil : payload, reply_to: replyTo)
        try await client.from("messages").insert(row).execute()
    }

    /// Your own words, within 15 minutes. The server holds the rules.
    public func edit(_ id: UUID, body: String) async throws {
        try await client.rpc("dm_edit", params: ["p_id": id.uuidString, "p_body": body]).execute()
    }

    public func unsend(_ id: UUID) async throws {
        try await client.rpc("dm_unsend", params: ["p_id": id.uuidString]).execute()
    }

    /// Nil takes your reaction back.
    public func react(_ id: UUID, _ emoji: String?) async throws {
        let params: [String: AnyJSON] = ["p_id": .string(id.uuidString), "p_emoji": emoji.map(AnyJSON.string) ?? .null]
        try await client.rpc("dm_react", params: params).execute()
    }

    public static let reactions = ["❤️", "😂", "😮", "😢", "🔥", "👍"]

    /// Local first so the badge clears at once. Always asks the server: a message realtime just
    /// delivered isn't counted in `threads` yet. The update policy limits it to rows you received.
    public func markRead(_ other: UUID) async {
        if let i = threads.firstIndex(where: { $0.otherID == other }) { threads[i].unread = 0 }
        do {
            try await client
                .from("messages")
                .update(["read_at": Date()])
                .eq("sender_id", value: other)
                .is("read_at", value: nil)
                .execute()
        } catch {
            MixLog.sync.error("[Messages] mark read failed: \(error)")
        }
    }

    /// Whether you've blocked them. RLS only shows your own blocks.
    public func isBlocked(_ other: UUID) async -> Bool {
        struct Row: Decodable { let blocked_id: UUID }
        let rows: [Row] = (try? await client
            .from("dm_blocks")
            .select("blocked_id")
            .eq("blocked_id", value: other)
            .execute()
            .value) ?? []
        return !rows.isEmpty
    }

    public func setBlocked(_ other: UUID, _ blocked: Bool) async throws {
        if blocked {
            try await client.from("dm_blocks").insert(["blocked_id": other]).execute()
        } else {
            try await client.from("dm_blocks").delete().eq("blocked_id", value: other).execute()
        }
        await refresh()
    }

    // MARK: Realtime

    /// Called from onRealtimeReady, next to InboxService.start. Received and sent rows on
    /// separate filters, plus updates to both: reads, edits, unsends and reactions.
    public func start(userID: UUID) {
        let previous = listenTask
        previous?.cancel()
        listenTask = Task { [weak self] in
            // The client keeps one channel per topic, so the old one has to be gone first.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let uid = userID.uuidString.lowercased()
            let channel = client.channel("messages-\(uid)")
            let toMe = RealtimePostgresFilter.eq("recipient_id", value: uid)
            let fromMe = RealtimePostgresFilter.eq("sender_id", value: uid)
            let received = channel.postgresChange(InsertAction.self, table: "messages", filter: toMe)
            let sent = channel.postgresChange(InsertAction.self, table: "messages", filter: fromMe)
            let changedToMe = channel.postgresChange(UpdateAction.self, table: "messages", filter: toMe)
            let changedFromMe = channel.postgresChange(UpdateAction.self, table: "messages", filter: fromMe)
            await client.join(channel, label: "messages")
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await a in received { await self.arrived(a) } }
                group.addTask { for await a in sent { await self.arrived(a) } }
                group.addTask { for await a in changedToMe { await self.changed(a) } }
                group.addTask { for await a in changedFromMe { await self.changed(a) } }
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
        threads = []
        loaded = false
        viewing = nil
    }

    private func arrived(_ action: InsertAction) {
        if let message = try? action.decodeRecord(as: Message.self, decoder: AnyJSON.decoder) {
            incoming.send(message)
        }
        poke()
    }

    private func changed(_ action: UpdateAction) {
        if let message = try? action.decodeRecord(as: Message.self, decoder: AnyJSON.decoder) {
            updated.send(message)
        }
        poke()
    }

    /// The pair's private channel, "dm:<lower id>:<higher id>", for typing. Nothing on it is stored.
    public func pairChannel(with other: UUID) async -> RealtimeChannelV2? {
        guard let me = try? await client.auth.session.user.id else { return nil }
        let ids = [me, other].map { $0.uuidString.lowercased() }.sorted()
        await client.connectRealtimeSocket()
        return client.channel("dm:\(ids[0]):\(ids[1])") { $0.isPrivate = true }
    }

    /// Coalesces bursts: marking a thread read sends one UPDATE per row.
    private func poke() {
        pokeTask?.cancel()
        pokeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Attachments

    private static let bucket = "dm-attachments"
    /// Photos per pick. The bucket caps each file at 10 MB.
    public static let photoLimit = 10
    public static let stickers = ["heart", "fire", "cassette", "vinyl", "headphones", "boombox",
                                  "mic", "notes", "eq", "play", "star", "bolt"]

    public struct Photo: Sendable {
        public let data: Data
        public let ext: String
        public let width: Double
        public let height: Double
    }

    /// JPEG no longer than `max` on its long edge. GIFs go as they are so they keep moving.
    @concurrent public nonisolated static func preparePhoto(_ data: Data, max: CGFloat = 2048) async -> Photo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetType(source) as String? == UTType.gif.identifier {
            guard data.count <= 10 * 1024 * 1024, let size = ImageDownsampler.pixelSize(of: data) else { return nil }
            return Photo(data: data, ext: "gif", width: size.width, height: size.height)
        }
        guard let jpeg = ImageDownsampler.downsampledJPEG(from: data, maxDimension: max, compressionQuality: 0.85),
              let size = ImageDownsampler.pixelSize(of: jpeg) else { return nil }
        return Photo(data: jpeg, ext: "jpg", width: size.width, height: size.height)
    }

    /// Into your own folder, the only one the bucket lets you write.
    private func upload(_ photo: Photo) async throws -> String {
        let me = try await client.auth.session.user.id.uuidString.lowercased()
        let path = "\(me)/\(UUID().uuidString.lowercased()).\(photo.ext)"
        try await client.storage.from(Self.bucket).upload(
            path, data: photo.data, options: FileOptions(contentType: photo.ext == "gif" ? "image/gif" : "image/jpeg"))
        return path
    }

    public func sendPhoto(id: UUID, to other: UUID, photo: Photo) async throws -> Payload {
        var payload = Payload()
        payload.path = try await upload(photo)
        payload.w = photo.width
        payload.h = photo.height
        try await send(id: id, to: other, kind: .image, payload: payload)
        return payload
    }

    // ponytail: one request per photo, kept for the session; batch if threads get photo-heavy.
    @ObservationIgnored private var signed: [String: URL] = [:]

    /// A day-long link to a photo in a message you're part of.
    public func attachmentURL(_ path: String) async -> URL? {
        if let hit = signed[path] { return hit }
        let url = try? await client.storage.from(Self.bucket).createSignedURL(path: path, expiresIn: 86_400)
        signed[path] = url
        return url
    }

    // MARK: Shares

    /// Covers we link to rather than copy. Anything else would hand the sender the reader's address.
    public nonisolated static func linkableArtwork(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased(),
              ["dzcdn.net", "mzstatic.com", "scdn.co", "supabase.co", "mixtaped.tech"]
                .contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              // Signed links expire, so those get copied like any other.
              !url.path.contains("/object/sign/")
        else { return nil }
        return url.absoluteString
    }

    /// A share card. `cover` is a small copy of the artwork for when there's no link to it.
    public func sendShare(id: UUID, to other: UUID, card: Payload, cover: Data?) async throws -> Payload {
        var payload = card
        if payload.artwork == nil, let cover,
           let photo = await Self.preparePhoto(cover, max: 300) {
            payload.path = try? await upload(photo)
        }
        try await send(id: id, to: other, kind: .share, payload: payload)
        return payload
    }

    // MARK: Links

    /// The body with only Mixtape links made tappable, so a message can't dress up somewhere else.
    public nonisolated static func linkified(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for match in text.matches(of: #/https?://\S+/#) {
            // Trailing punctuation is the sentence's, not the link's.
            let raw = String(text[match.range]).replacing(#/[.,!?;:)\]]+$/#, with: "")
            let end = text.index(match.range.lowerBound, offsetBy: raw.count)
            guard let url = URL(string: raw),
                  let host = url.host()?.lowercased(),
                  host == "mixtaped.tech" || host == "www.mixtaped.tech",
                  let range = Range(match.range.lowerBound..<end, in: out)
            else { continue }
            out[range].link = url
        }
        return out
    }
}

extension MessagesService.Message {
    /// Rows from before the attachments migration have no kind, and a kind this build
    /// doesn't know reads as text.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        senderID = try c.decode(UUID.self, forKey: .senderID)
        recipientID = try c.decode(UUID.self, forKey: .recipientID)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(MessagesService.Kind.init) } ?? .text
        payload = try? c.decodeIfPresent(MessagesService.Payload.self, forKey: .payload)
        readAt = try? c.decodeIfPresent(Date.self, forKey: .readAt)
        editedAt = try? c.decodeIfPresent(Date.self, forKey: .editedAt)
        unsentAt = try? c.decodeIfPresent(Date.self, forKey: .unsentAt)
        replyTo = try? c.decodeIfPresent(UUID.self, forKey: .replyTo)
        senderReaction = try? c.decodeIfPresent(String.self, forKey: .senderReaction)
        recipientReaction = try? c.decodeIfPresent(String.self, forKey: .recipientReaction)
    }
}
