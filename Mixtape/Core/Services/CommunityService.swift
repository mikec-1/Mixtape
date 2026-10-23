// Community posts (SONG-EDITS-PLAN section 7). A post is an edit's recipe with a title, caption and
// cover; listeners rebuild the audio from their own copy of the original, like a synced edit.
// Studio edits only render on a Mac, so theirs carry the rendered file instead.
// Tables: supabase/migrations/20261003010000_community.sql. Same calls as mixtape-web
// src/lib/community.ts, keep them in sync.

import Foundation
import Combine
import Supabase
import Observation

/// A `post_cards` row: the post with its author, counts and your like and repost.
public struct CommunityPost: Identifiable, Decodable, Hashable, Sendable {
    public let id: UUID
    public let shareCode: String
    public let title: String
    public let caption: String?
    public let artworkPath: String?
    public let edit: SongEdit
    public let originalTitle: String
    public let originalArtist: String?
    /// The edit's length.
    public let duration: TimeInterval?
    public let createdAt: Date
    public let userID: UUID
    public let username: String?
    public let displayName: String?
    public let avatarURL: String?
    public var likes: Int
    public var reposts: Int
    public var comments: Int
    public var plays: Int
    public var liked: Bool
    public var reposted: Bool
    /// The song's shape as base64 bytes. Nil on posts from before waveforms.
    public var waveform: String?
    /// The posted file in the audio bucket, on studio edits. Nil means rebuild from the recipe.
    public let audioPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, caption, edit, duration, username, likes, reposts, comments, plays, liked, reposted, waveform
        case shareCode = "share_code", artworkPath = "artwork_path"
        case originalTitle = "original_title", originalArtist = "original_artist"
        case createdAt = "created_at", userID = "user_id"
        case displayName = "display_name", avatarURL = "avatar_url", audioPath = "audio_path"
    }

    public var artworkURL: URL? { artworkPath.map(CommunityService.artworkURL) }
    public var link: URL { MixtapeLink.post(shareCode) }
    public var author: UserProfile {
        UserProfile(id: userID, username: username ?? "", displayName: displayName,
                    avatarURL: avatarURL.flatMap(URL.init(string:)))
    }

    /// The post as a song the player can queue. It isn't in anyone's library until they save it.
    public func track(artwork: Data?) -> Track {
        var file = FileProvenance.editPlaceholder
        if let audioPath {
            file.fileHash = "post-\(id.uuidString.lowercased())"
            file.remoteKey = audioPath
            file.uploaded = true
        }
        return Track(id: id, title: title, artistName: originalArtist ?? "", albumTitle: "",
                     duration: duration ?? 0, artworkData: artwork,
                     sync: SyncMetadata(deviceID: ""), file: file, edit: edit)
    }
}

public enum CommunityFeed: String, CaseIterable, Identifiable, Sendable {
    case following, hot, new, top
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
}

/// The style filters. Raw values are the `posts.styles` entries.
public enum PostStyle: String, CaseIterable, Identifiable, Sendable {
    case slowed, spedUp = "sped_up", reverb, nightcore
    public var id: Self { self }
    public var title: String {
        switch self {
        case .slowed: "Slowed"
        case .spedUp: "Sped Up"
        case .reverb: "Reverb"
        case .nightcore: "Nightcore"
        }
    }
}

public enum ProfilePostsTab: String, CaseIterable, Identifiable, Sendable {
    case posts, reposts, likes
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
}

/// A post in a list. Following and profile rows carry when it happened, and Following who did it.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public var post: CommunityPost
    public var kind: String?
    public var at: Date?
    public var actor: String?
    public var others = 0
    public var id: UUID { post.id }

    /// "Liked by Sam and 2 others". Nil for a post, since the row already names its author.
    public var activity: String? {
        guard let actor, kind == "liked" || kind == "reposted" else { return nil }
        let who = others > 0 ? "\(actor) and \(others) other\(others == 1 ? "" : "s")" : actor
        return kind == "liked" ? "Liked by \(who)" : "Reposted by \(who)"
    }
}

/// A comment from `post_thread`, oldest first. Replies point at their parent.
public struct PostComment: Identifiable, Decodable, Hashable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    /// Seconds into the edit, for a timed comment.
    public let atSeconds: Double?
    public let body: String
    public let createdAt: Date
    public let userID: UUID
    public let username: String?
    public let displayName: String?
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, body, username
        case parentID = "parent_id", atSeconds = "at_seconds", createdAt = "created_at"
        case userID = "user_id", displayName = "display_name", avatarURL = "avatar_url"
    }

    public var author: UserProfile {
        UserProfile(id: userID, username: username ?? "", displayName: displayName,
                    avatarURL: avatarURL.flatMap(URL.init(string:)))
    }
}

/// The playing post's timed comments, for the dots on the player's scrubber.
@Observable
@MainActor
public final class PlayingPostMarks {
    public static let shared = PlayingPostMarks()
    public fileprivate(set) var post: UUID?
    public fileprivate(set) var comments: [PostComment] = []
}

@MainActor
public final class CommunityService {

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public nonisolated static func isCode(_ code: String) -> Bool {
        code.wholeMatch(of: /[A-Za-z0-9_-]{12}/) != nil
    }

    /// Public bucket, so the URL is derived.
    public nonisolated static func artworkURL(_ path: String) -> URL {
        SupabaseConfig.projectURL.appending(path: "storage/v1/object/public/post-artwork/\(path)")
    }

    public func post(code: String) async throws -> CommunityPost? {
        guard Self.isCode(code) else { return nil }
        let rows: [CommunityPost] = try await client.from("post_cards").select()
            .eq("share_code", value: code).limit(1).execute().value
        return rows.first
    }

    /// Posts an edit from the library. The row goes first so the artwork can be filed under its id;
    /// a failed upload leaves a post without a cover rather than no post. `audio` is a studio edit's
    /// file, uploaded before the row since the row names it.
    public func create(edit: Track, original: Track, title: String, caption: String,
                       artwork: Data?, waveform: String?, audio: URL? = nil) async throws -> (code: String, artworkFailed: Bool) {
        guard let recipe = edit.edit else { throw Failure("Only edits can be posted.") }
        struct Insert: Encodable {
            let title: String
            let caption: String?
            let edit: SongEdit
            let original_title: String
            let original_artist: String?
            let duration: Double?
            let waveform: String?
            let audio_path: String?
        }
        struct Created: Decodable { let id: UUID; let share_code: String; let user_id: UUID }
        var audioPath: String?
        if let audio {
            let ext = audio.pathExtension.lowercased()
            do {
                // Lowercased: the bucket policy compares the folder to auth.uid()::text.
                let me = try await client.auth.session.user.id.uuidString.lowercased()
                let path = "\(me)/posts/\(UUID().uuidString.lowercased()).\(ext)"
                try await client.storage.from(SupabaseFileStorageService.bucket)
                    .upload(path, data: try Data(contentsOf: audio),
                            options: FileOptions(contentType: SupabaseFileStorageService.contentType(for: ext)))
                audioPath = path
            } catch {
                throw Failure("Couldn\u{2019}t upload this song.")
            }
        }
        let row: Created
        do {
            row = try await client.from("posts")
                .insert(Insert(title: title, caption: caption.isEmpty ? nil : caption, edit: recipe,
                               original_title: original.displayTitle,
                               original_artist: original.artistName.isEmpty ? nil : original.artistName,
                               duration: edit.duration > 0 ? edit.duration : nil, waveform: waveform,
                               audio_path: audioPath))
                .select("id, share_code, user_id").single().execute().value
        } catch {
            if let audioPath { _ = try? await client.storage.from(SupabaseFileStorageService.bucket).remove(paths: [audioPath]) }
            let message = (error as? PostgrestError)?.message ?? ""
            throw Failure(message.contains("20 songs") ? message : "Couldn\u{2019}t post this song.")
        }

        guard let artwork else { return (row.share_code, false) }
        // Lowercased: the bucket policy compares the folder to auth.uid()::text.
        let path = "\(row.user_id.uuidString.lowercased())/\(row.id.uuidString.lowercased()).jpg"
        do {
            guard let jpeg = ImageDownsampler.downsampledJPEG(from: artwork, maxDimension: 800) else {
                return (row.share_code, true)
            }
            try await client.storage.from("post-artwork")
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
            try await client.from("posts").update(["artwork_path": path]).eq("id", value: row.id).execute()
            return (row.share_code, false)
        } catch {
            return (row.share_code, true)
        }
    }

    public func delete(_ post: CommunityPost) async throws {
        try await client.from("posts").delete().eq("id", value: post.id).execute()
        if let path = post.artworkPath { _ = try? await client.storage.from("post-artwork").remove(paths: [path]) }
        if let path = post.audioPath { _ = try? await client.storage.from(SupabaseFileStorageService.bucket).remove(paths: [path]) }
    }

    /// Fills in the shape of an older post. Owners only, by the grant.
    public func setWaveform(_ postID: UUID, _ waveform: String) async throws {
        try await client.from("posts").update(["waveform": waveform]).eq("id", value: postID).execute()
    }

    public func setLiked(_ postID: UUID, _ on: Bool) async throws { try await toggle("post_likes", postID, on) }
    public func setReposted(_ postID: UUID, _ on: Bool) async throws { try await toggle("post_reposts", postID, on) }

    private func toggle(_ table: String, _ postID: UUID, _ on: Bool) async throws {
        do {
            if on {
                try await client.from(table).insert(["post_id": postID]).execute()
            } else {
                let me = try await client.auth.session.user.id
                try await client.from(table).delete().eq("post_id", value: postID).eq("user_id", value: me).execute()
            }
        } catch let error as PostgrestError where error.code == "23505" {
            // Already liked from another device is fine.
        }
    }

    /// Counted once per person per day. Never throws; a play count isn't worth an error.
    public func play(_ postID: UUID) {
        Task { _ = try? await client.rpc("play_post", params: ["p_post": postID]).execute() }
        let marks = PlayingPostMarks.shared
        if marks.post != postID { marks.post = postID; marks.comments = [] }
        Task { _ = try? await thread(postID) }
    }

    /// Also refreshes the player's dots when it's the playing post's thread.
    public func thread(_ postID: UUID) async throws -> [PostComment] {
        let rows: [PostComment] = try await client.rpc("post_thread", params: ["p_post": postID]).execute().value
        let marks = PlayingPostMarks.shared
        if marks.post == postID { marks.comments = rows.filter { $0.atSeconds != nil } }
        return rows
    }

    public func addComment(_ postID: UUID, body: String, parentID: UUID?, atSeconds: Double?) async throws {
        struct Insert: Encodable { let post_id: UUID; let body: String; let parent_id: UUID?; let at_seconds: Double? }
        do {
            try await client.from("post_comments")
                .insert(Insert(post_id: postID, body: body, parent_id: parentID, at_seconds: atSeconds)).execute()
        } catch {
            let message = (error as? PostgrestError)?.message ?? ""
            throw Failure(message.contains("a day") ? message : "Couldn\u{2019}t post that comment.")
        }
    }

    public func deleteComment(_ id: UUID) async throws {
        try await client.from("post_comments").delete().eq("id", value: id).execute()
    }

    public func report(_ postID: UUID, comment: UUID? = nil, reason: String) async throws {
        struct Insert: Encodable { let post_id: UUID; let comment_id: UUID?; let reason: String }
        try await client.from("post_reports").insert(Insert(post_id: postID, comment_id: comment, reason: reason)).execute()
    }

    // MARK: - Feeds and follows

    public nonisolated static let pageSize = 30

    private struct ActivityRow: Decodable {
        let card: CommunityPost
        let kind: String?
        let at: Date
        let actor_username: String?
        let actor_display_name: String?
        let others: Int?

        var item: FeedItem {
            let name = actor_display_name?.trimmingCharacters(in: .whitespaces)
            return FeedItem(post: card, kind: kind, at: at,
                            actor: name?.isEmpty == false ? name : actor_username, others: others ?? 0)
        }
    }

    private struct Page: Encodable {
        var p_user: UUID?
        var p_kind: String?
        let p_before: Date?
        let p_limit = CommunityService.pageSize
    }

    /// The next page after `loaded`. Hot, New and Top page by offset, Following by time.
    /// ponytail: offset paging, so a post that climbs Hot mid-scroll can repeat; callers drop repeats by id.
    public func feed(_ feed: CommunityFeed, style: PostStyle?, allTime: Bool,
                     after loaded: [FeedItem]) async throws -> [FeedItem] {
        if feed == .following {
            let rows: [ActivityRow] = try await client
                .rpc("feed_following", params: Page(p_before: loaded.last?.at)).execute().value
            return rows.map(\.item)
        }
        var query = client.from("post_cards").select()
        if let style { query = query.contains("styles", value: [style.rawValue]) }
        if feed == .top, !allTime { query = query.gte("created_at", value: Date.now.addingTimeInterval(-7 * 86_400)) }
        let posts: [CommunityPost] = try await query
            .order(feed == .hot ? "hot" : feed == .top ? "score" : "created_at", ascending: false)
            .order("created_at", ascending: false)
            .range(from: loaded.count, to: loaded.count + Self.pageSize - 1)
            .execute().value
        return posts.map { FeedItem(post: $0) }
    }

    public func profile(_ user: UUID, _ tab: ProfilePostsTab, after loaded: [FeedItem]) async throws -> [FeedItem] {
        guard tab == .posts else {
            let rows: [ActivityRow] = try await client
                .rpc("profile_activity", params: Page(p_user: user, p_kind: tab.rawValue, p_before: loaded.last?.at))
                .execute().value
            return rows.map(\.item)
        }
        let posts: [CommunityPost] = try await client.from("post_cards").select()
            .eq("user_id", value: user).order("created_at", ascending: false)
            .range(from: loaded.count, to: loaded.count + Self.pageSize - 1)
            .execute().value
        return posts.map { FeedItem(post: $0, at: $0.createdAt) }
    }

    /// Follower and following counts, and whether you follow them.
    public func follows(of user: UUID) async throws -> (followers: Int, following: Int, mine: Bool) {
        func count(_ column: String, _ id: UUID, also: (String, UUID)? = nil) async throws -> Int {
            var query = client.from("follows").select("*", head: true, count: .exact).eq(column, value: id)
            if let also { query = query.eq(also.0, value: also.1) }
            return try await query.execute().count ?? 0
        }
        async let followers = count("followee_id", user)
        async let following = count("follower_id", user)
        var mine = false
        if let me = client.auth.currentUser?.id, me != user {
            mine = try await count("followee_id", user, also: ("follower_id", me)) > 0
        }
        return (try await followers, try await following, mine)
    }

    public func setFollowing(_ user: UUID, _ on: Bool) async throws {
        do {
            if on {
                try await client.from("follows").insert(["followee_id": user]).execute()
            } else {
                let me = try await client.auth.session.user.id
                try await client.from("follows").delete()
                    .eq("follower_id", value: me).eq("followee_id", value: user).execute()
            }
        } catch let error as PostgrestError where error.code == "23505" {
            // Already following from another device.
        }
    }
}
