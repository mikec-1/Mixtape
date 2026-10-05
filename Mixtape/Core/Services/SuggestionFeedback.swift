// "Don't suggest this again": blocked songs and artists. Filters mix radios,
// autoplay, mix seeds and the stored shelves.
// In UserDefaults so it can be read off the main actor mid-fetch. Synced to the
// account's `suggestion_feedback` row: every edit pushes both sets, realtime and
// each sync pull bring other devices' edits in.

import Foundation
import os
import Supabase

public enum SuggestionFeedback {

    private static let songsKey   = "mix.suggestions.hiddenSongs"
    private static let artistsKey = "mix.suggestions.blockedArtists"

    /// Lowercased `title|artist`, the shared cross-source key.
    public static func key(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    // MARK: - Reading

    public static var hiddenSongs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: songsKey) ?? [])
    }

    /// Folded through `ArtistAliases`, so "Digga D" also blocks "Digga".
    public static var blockedArtists: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: artistsKey) ?? [])
    }

    public static func isHidden(title: String, artist: String) -> Bool {
        hiddenSongs.contains(key(title: title, artist: artist))
    }

    public static func isBlocked(artist: String) -> Bool {
        blockedArtists.contains(ArtistAliases.fold(artist))
    }

    /// What filtering reads: the hidden list plus songs this device saw skipped early.
    public static var filteredSongs: Set<String> {
        hiddenSongs.union(SkipHistory.skippedOut)
    }

    /// Every credited artist counts, so features by blocked artists are filtered too.
    public static func allows(title: String, artist: String) -> Bool {
        allows(title: title, artist: artist, songs: filteredSongs, artists: blockedArtists)
    }

    /// Takes the sets, so filtering a whole shelf reads them once.
    static func allows(title: String, artist: String, songs: Set<String>, artists: Set<String>) -> Bool {
        guard !songs.contains(key(title: title, artist: artist)) else { return false }
        guard !artists.isEmpty else { return true }
        return !ImportService.creditedArtists(from: artist)
            .contains { artists.contains(ArtistAliases.fold($0)) }
    }

    public static func allows(_ track: Track) -> Bool {
        allows(title: track.identityTitle, artist: track.artistName)
    }

    public static func allows(_ track: OnlineTrack) -> Bool {
        allows(title: track.title, artist: track.artistName)
    }

    // MARK: - Writing

    public static func hide(title: String, artist: String) {
        var songs = hiddenSongs
        guard songs.insert(key(title: title, artist: artist)).inserted else { return }
        edit(songs: songs, artists: blockedArtists)
    }

    public static func unhide(title: String, artist: String) {
        var songs = hiddenSongs
        guard songs.remove(key(title: title, artist: artist)) != nil else { return }
        edit(songs: songs, artists: blockedArtists)
    }

    public static func block(artist: String) {
        let folded = ArtistAliases.fold(artist)
        guard !folded.isEmpty else { return }
        var artists = blockedArtists
        guard artists.insert(folded).inserted else { return }
        edit(songs: hiddenSongs, artists: artists)
    }

    public static func unblock(artist: String) {
        var artists = blockedArtists
        guard artists.remove(ArtistAliases.fold(artist)) != nil else { return }
        edit(songs: hiddenSongs, artists: artists)
    }

    /// "Show These Again" and a library wipe. Clears the account's copy too.
    public static func clear() {
        SkipHistory.clear()
        edit(songs: [], artists: [])
    }

    // MARK: - Account sync

    /// Set by a local edit, cleared once the server has it. A dirty device wins its next pull.
    private static let dirtyKey = "mix.suggestions.dirty"
    /// Whose sets these are. Nil on a device that predates sync, whose sets merge in once.
    private static let ownerKey = "mix.suggestions.owner"

    private struct Row: Codable {
        var userID: UUID?
        var hiddenSongs: [String]
        var blockedArtists: [String]

        enum CodingKeys: String, CodingKey {
            case userID = "user_id", hiddenSongs = "hidden_songs", blockedArtists = "blocked_artists"
        }
    }

    private static func edit(songs: Set<String>, artists: Set<String>) {
        write(songs: songs, artists: artists)
        UserDefaults.standard.set(true, forKey: dirtyKey)
        Task { await push() }
    }

    private static func write(songs: Set<String>, artists: Set<String>) {
        let defaults = UserDefaults.standard
        if songs.isEmpty { defaults.removeObject(forKey: songsKey) } else { defaults.set(Array(songs), forKey: songsKey) }
        if artists.isEmpty { defaults.removeObject(forKey: artistsKey) } else { defaults.set(Array(artists), forKey: artistsKey) }
        NotificationCenter.default.post(name: .suggestionFeedbackChanged, object: nil)
    }

    private static func push() async {
        guard let userID = SupabaseConfig.client.auth.currentUser?.id else { return }
        let songs = hiddenSongs, artists = blockedArtists
        do {
            try await SupabaseConfig.client.from("suggestion_feedback")
                .upsert(Row(userID: userID, hiddenSongs: songs.sorted(), blockedArtists: artists.sorted()),
                        onConflict: "user_id", returning: .minimal)
                .execute()
            UserDefaults.standard.set(userID.uuidString, forKey: ownerKey)
            // An edit that landed mid-flight still owes its own push.
            if hiddenSongs == songs, blockedArtists == artists {
                UserDefaults.standard.set(false, forKey: dirtyKey)
            }
        } catch {
            MixLog.sync.error("Suggestion feedback push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reconciles with the account's row. Runs on every sync pull and realtime change.
    public static func pull(userID: UUID) async {
        let remote: Row?
        do {
            let rows: [Row] = try await SupabaseConfig.client.from("suggestion_feedback")
                .select("hidden_songs,blocked_artists")
                .eq("user_id", value: userID)
                .execute()
                .value
            remote = rows.first
        } catch {
            MixLog.sync.error("Suggestion feedback pull failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: ownerKey)
        let songs = hiddenSongs, artists = blockedArtists
        let remoteSongs = Set(remote?.hiddenSongs ?? []), remoteArtists = Set(remote?.blockedArtists ?? [])

        if owner == nil, !songs.isEmpty || !artists.isEmpty {
            // First sync on a device that already had choices: keep both.
            edit(songs: songs.union(remoteSongs), artists: artists.union(remoteArtists))
        } else if owner == userID.uuidString, defaults.bool(forKey: dirtyKey) {
            await push()
        } else {
            defaults.set(userID.uuidString, forKey: ownerKey)
            defaults.set(false, forKey: dirtyKey)
            if remoteSongs != songs || remoteArtists != artists {
                write(songs: remoteSongs, artists: remoteArtists)
            }
        }
    }
}

/// Songs skipped in their first 30 seconds, counted per account on this device only.
/// Never uploaded, so it works without the analytics opt-in. Two early skips keep a song
/// out of suggestions; a full listen forgives it.
public enum SkipHistory {

    static let threshold = 2

    private static var countsKey: String {
        "mix.skips.\(SupabaseConfig.client.auth.currentUser?.id.uuidString ?? "local")"
    }

    // ponytail: grows by one entry per early-skipped song, no cap; trim oldest if it ever gets big.
    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: countsKey) }
    }

    static var skippedOut: Set<String> {
        Set(counts.filter { $0.value >= threshold }.keys)
    }

    public static func noteEarlySkip(title: String, artist: String) {
        guard !PrivateSession.isActive else { return }
        let key = SuggestionFeedback.key(title: title, artist: artist)
        var all = counts
        all[key, default: 0] += 1
        counts = all
        if all[key] == threshold { NotificationCenter.default.post(name: .suggestionFeedbackChanged, object: nil) }
    }

    public static func forgive(title: String, artist: String) {
        var all = counts
        guard let was = all.removeValue(forKey: SuggestionFeedback.key(title: title, artist: artist)) else { return }
        counts = all
        if was >= threshold { NotificationCenter.default.post(name: .suggestionFeedbackChanged, object: nil) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: countsKey)
    }
}

extension Notification.Name {
    /// A song or artist was hidden or shown again, here or on another device.
    public static let suggestionFeedbackChanged = Notification.Name("mix.suggestionFeedbackChanged")
}
