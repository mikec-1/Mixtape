// SupabaseSyncService.swift
// Mixtape — Core/Services
//
// Syncs track/album/artist metadata between the local SwiftData store
// and the Supabase PostgreSQL backend.
//
// Strategy:
//   Push  — upsert all locally modified records to the server.
//   Pull  — fetch server records updated since the last pull; merge into local DB.
//   Conflict — Last-Write-Wins on updated_at. The most recently modified copy wins.
//
// Artwork is NOT synced here — it travels with the audio file.

import Foundation
import SwiftData
import Supabase
import Combine
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class SupabaseSyncService: ObservableObject, SyncServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var syncState: SyncState = .idle

    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        $syncState.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    private let client:         SupabaseClient
    private let context:        ModelContext
    private let libraryService: LibraryService
    private let deviceID:       String

    // MARK: - Private State

    private var currentUser:    AppUser?
    private var backgroundTask: Task<Void, Never>?
    private var isSyncing = false

    /// Realtime listener that signs the user out the instant this device's row
    /// is deleted from the `devices` table (a "force logout" from the web).
    private var revocationChannel: RealtimeChannelV2?
    private var revocationTask:    Task<Void, Never>?

    /// Invoked when this device is revoked remotely. Wired by AppDependencies to
    /// the auth service's sign-out. Runs on the main actor.
    public var onDeviceRevoked: (() async -> Void)?

    // MARK: - Init

    public init(
        client:         SupabaseClient,
        context:        ModelContext,
        libraryService: LibraryService,
        deviceID:       String
    ) {
        self.client         = client
        self.context        = context
        self.libraryService = libraryService
        self.deviceID       = deviceID
    }

    // MARK: - Lifecycle

    public func onSignIn(user: AppUser, accessToken: String) async {
        currentUser = user
        syncState   = .pendingChanges(count: pendingCount())
        // Register this device, then kick off an immediate first sync.
        Task {
            await registerDevice(userID: user.id)
            try? await sync()
        }
        startRevocationListener(userID: user.id)
    }

    public func onSignOut() async {
        stopBackgroundSync()
        await stopRevocationListener()
        currentUser = nil
        syncState   = .idle
    }

    // MARK: - Sync

    public func sync() async throws {
        guard let user = currentUser, !isSyncing else { return }
        isSyncing = true
        syncState = .syncing
        defer { isSyncing = false }

        print("[Sync] ▶︎ Sync started")
        if let allTracks = try? context.fetch(FetchDescriptor<TrackEntity>()) {
            let withArt = allTracks.filter { $0.artworkData != nil }.count
            let withKey = allTracks.filter { $0.artworkKey != nil }.count
            print("[Sync Debug] Tracks - Total: \(allTracks.count), with artworkData: \(withArt), with artworkKey: \(withKey)")
        }
        if let allAlbums = try? context.fetch(FetchDescriptor<AlbumEntity>()) {
            let withArt = allAlbums.filter { $0.artworkData != nil }.count
            let withKey = allAlbums.filter { $0.artworkKey != nil }.count
            print("[Sync Debug] Albums - Total: \(allAlbums.count), with artworkData: \(withArt), with artworkKey: \(withKey)")
        }
        if let allArtists = try? context.fetch(FetchDescriptor<ArtistEntity>()) {
            let withArt = allArtists.filter { $0.artworkData != nil }.count
            let withKey = allArtists.filter { $0.artworkKey != nil }.count
            print("[Sync Debug] Artists - Total: \(allArtists.count), with artworkData: \(withArt), with artworkKey: \(withKey)")
        }
        do {
            try await pushAll(userID: user.id)
            try await pullAll(userID: user.id)
            try await uploadPendingFiles(userID: user.id)
            try await uploadPendingArtworks(userID: user.id)
            try await downloadPendingArtworks(userID: user.id)
            await registerDevice(userID: user.id)
            libraryService.refresh()
            syncState = .upToDate(lastSynced: Date())
            print("[Sync] ✅ Sync complete")
        } catch {
            syncState = .error(error.localizedDescription)
            print("[Sync] ❌ Sync failed: \(error)")
            throw error
        }
    }

    /// Generic single-entity push (protocol requirement; caller supplies a complete row struct).
    public func push<T: Codable>(_ entity: T, table: String) async throws {
        guard currentUser != nil else { return }
        try await client.from(table).upsert(entity).execute()
    }

    // MARK: - Device Registration

    /// Upserts this install into the `devices` table so it appears on the web
    /// /devices page. Reuses the stable `deviceID` (same one used for sync
    /// attribution). Best-effort: a failure never blocks sync.
    private func registerDevice(userID: UUID) async {
        let row = DeviceRow(
            userID:     userID,
            deviceID:   deviceID,
            platform:   Self.platformName,
            name:       Self.deviceName,
            appVersion: Self.appVersion,
            lastSeenAt: Date()
        )
        do {
            try await client.from("devices")
                .upsert(row, onConflict: "user_id,device_id")
                .execute()
        } catch {
            print("[Sync] device register failed: \(error)")
        }
    }

    // MARK: - Remote Revocation (force logout)

    /// Subscribes to realtime DELETE events on this device's `devices` row.
    /// When the row is removed (e.g. revoked from the web /devices page), the
    /// app signs out immediately. Best-effort: if Realtime is unavailable, the
    /// next background sync still won't recreate access — this just makes it
    /// instant rather than waiting on token expiry.
    private func startRevocationListener(userID: UUID) {
        stopRevocationListenerSync()

        let channel = client.channel("device-revocation-\(deviceID)")
        revocationChannel = channel

        revocationTask = Task { [weak self] in
            guard let self else { return }

            // NOTE: we deliberately do NOT use a server-side `filter:` here.
            // Realtime's postgres_changes filtering on DELETE is unreliable (the
            // filter is evaluated against replica-identity columns and often
            // drops events), so we subscribe to all DELETEs on `devices` — RLS
            // already scopes these to the signed-in user — and match our own
            // row client-side.
            let deletions = channel.postgresChange(
                DeleteAction.self,
                schema: "public",
                table:  "devices"
            )

            await channel.subscribe()
            print("[Sync] 👂 Revocation listener subscribed (device \(deviceID))")

            for await deletion in deletions {
                guard !Task.isCancelled else { break }

                // The DELETE payload only reliably carries the primary key (the
                // `devices` table's replica identity is the default PK), so we
                // can't read device_id off `oldRecord`. Instead: any DELETE on
                // `devices` is — thanks to RLS — one of *this user's* devices.
                // Re-check whether our own row still exists; if it's gone, this
                // device was the one revoked.
                let oldDeviceID = deletion.oldRecord["device_id"]?.stringValue
                print("[Sync] 👂 devices DELETE received (device_id=\(oldDeviceID ?? "nil")) — verifying our row")
                if oldDeviceID != nil && oldDeviceID != deviceID { continue }

                if await deviceRowStillExists(userID: userID) {
                    print("[Sync] 👂 our device row still present — not us, ignoring")
                    continue
                }

                print("[Sync] 🔒 This device revoked remotely — signing out.")
                await onDeviceRevoked?()
                break
            }
        }
    }

    /// Returns true if this install's `devices` row is still present. Used to
    /// confirm a remote revocation actually removed *us*.
    private func deviceRowStillExists(userID: UUID) async -> Bool {
        struct Row: Decodable { let device_id: String }
        do {
            let rows: [Row] = try await client.from("devices")
                .select("device_id")
                .eq("user_id", value: userID)
                .eq("device_id", value: deviceID)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            // On a query error, don't force a logout — fail safe (stay signed in).
            print("[Sync] device existence check failed: \(error)")
            return true
        }
    }

    private func stopRevocationListener() async {
        revocationTask?.cancel()
        revocationTask = nil
        if let channel = revocationChannel {
            await channel.unsubscribe()
            revocationChannel = nil
        }
    }

    /// Synchronous teardown for use before starting a fresh listener.
    private func stopRevocationListenerSync() {
        revocationTask?.cancel()
        revocationTask = nil
        if let channel = revocationChannel {
            Task { await channel.unsubscribe() }
            revocationChannel = nil
        }
    }

    private struct DeviceRow: Encodable {
        let userID:     UUID
        let deviceID:   String
        let platform:   String
        let name:       String
        let appVersion: String
        let lastSeenAt: Date

        enum CodingKeys: String, CodingKey {
            case userID     = "user_id"
            case deviceID   = "device_id"
            case platform
            case name
            case appVersion = "app_version"
            case lastSeenAt = "last_seen_at"
        }
    }

    private static var platformName: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    // MARK: - Background Sync

    public func startBackgroundSync(intervalSeconds: TimeInterval) {
        stopBackgroundSync()
        backgroundTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                try? await sync()
            }
        }
    }

    public func stopBackgroundSync() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    // MARK: - Conflict Resolution

    public func resolveConflict(entityID: UUID, resolution: ConflictResolution) async throws {
        switch resolution {
        case .localWins:
            // Re-mark as pending so it gets re-pushed on the next sync.
            markPending(entityID: entityID)
            try context.save()
        case .serverWins:
            // Will be overwritten on the next pull — nothing to do locally.
            break
        }
        try? await sync()
    }

    // MARK: - Push

    private func pushAll(userID: UUID) async throws {
        try await pushTracks(userID: userID)
        try await pushAlbums(userID: userID)
        try await pushArtists(userID: userID)
        try await pushPlaylists(userID: userID)
    }

    private func pushTracks(userID: UUID) async throws {
        let pending = try fetchPendingTracks()
        guard !pending.isEmpty else { return }

        print("[Sync] ↑ Pushing \(pending.count) track(s): \(pending.map(\.title).joined(separator: ", "))")
        // FIX: SwiftData may cache entity.isDeleted=false even after softDelete() sets it to true.
        // Explicitly force isDeleted=true for any entity whose syncStatus is "deleted" so the
        // correct tombstone always reaches the server.
        let rows = pending.map { entity -> TrackRow in
            var row = TrackRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            return row
        }
        try await client.from("tracks").upsert(rows).execute()

        // Hard-delete confirmed deletions from SwiftData so the pull can't re-insert them.
        // Update non-deleted entities to "synced".
        var hardDeletedCount = 0
        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                context.delete(entity)
                hardDeletedCount += 1
            } else {
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
        if hardDeletedCount > 0 {
            print("[Sync] ↑ Pushed \(pending.count) track(s), hard-deleted \(hardDeletedCount) confirmed deletion(s)")
        } else {
            print("[Sync] ↑ Pushed \(pending.count) track(s)")
        }
    }

    private func pushAlbums(userID: UUID) async throws {
        let pending = try fetchPendingAlbums()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> AlbumRow in
            var row = AlbumRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            return row
        }
        try await client.from("albums").upsert(rows).execute()

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                context.delete(entity)
            } else {
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
    }

    private func pushArtists(userID: UUID) async throws {
        let pending = try fetchPendingArtists()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> ArtistRow in
            var row = ArtistRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            return row
        }
        try await client.from("artists").upsert(rows).execute()

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                context.delete(entity)
            } else {
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
    }

    private func pushPlaylists(userID: UUID) async throws {
        let pending = try fetchPendingPlaylists()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> PlaylistRow in
            var row = PlaylistRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            return row
        }
        try await client.from("playlists").upsert(rows, onConflict: "id,user_id").execute()

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                // System playlists (Favourites, All Songs) can never be hard-deleted locally.
                if entity.id == Playlist.favouritesID || entity.id == Playlist.allSongsID {
                    entity.syncStatus       = SyncStatus.synced.rawValue
                    entity.syncLastSyncedAt = Date()
                } else {
                    context.delete(entity)
                }
            } else {
                entity.syncStatus       = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
        print("[Sync] ↑ Playlists: pushed \(pending.count)")
    }

    // MARK: - File Upload
    //
    // Uploads local audio files that haven't been uploaded yet.
    // After each successful upload the track is marked modified so pushTracks
    // syncs the new remoteKey and fileUploaded=true back to the server.

    private func uploadPendingFiles(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingUpload()
        guard !tracks.isEmpty else { return }

        var uploadedAny = false

        var missingFileCount = 0

        for entity in tracks {
            // Verify the local file still exists (it might have been cleared).
            let localURL = URL.documentsDirectory.appending(path: entity.localPath)
            guard FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) else {
                missingFileCount += 1
                print("[SupabaseSyncService] ⚠️ Local file missing for \"\(entity.title)\" at \(entity.localPath) — skipping upload")
                continue
            }

            let ext        = localURL.pathExtension.lowercased()
            let remotePath = SupabaseFileStorageService.remotePath(
                userID:   userID,
                fileHash: entity.fileHash,
                ext:      ext
            )

            // Check file size on disk before we try to load it.
            let diskSize: Int64
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path(percentEncoded: false))
                diskSize = (attrs[.size] as? Int64) ?? 0
            } catch {
                print("[SupabaseSyncService] ⚠️ Can't stat \"\(entity.title)\": \(error) — skipping")
                continue
            }
            guard diskSize > 0 else {
                print("[SupabaseSyncService] ⚠️ \"\(entity.title)\" is 0 bytes on disk — skipping upload")
                continue
            }
            // If we stored a file size at import time, do a quick sanity check.
            if entity.fileSize > 0 && diskSize < entity.fileSize / 2 {
                print("[SupabaseSyncService] ⚠️ \"\(entity.title)\" disk size (\(diskSize)) is less than half of stored size (\(entity.fileSize)) — file may be truncated, skipping")
                continue
            }

            do {
                // Read file off the main thread — large lossless files can be 100+ MB.
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: localURL)
                }.value

                // Guard against empty or obviously-truncated reads before hitting the network.
                guard data.count > 0 else {
                    print("[SupabaseSyncService] ⚠️ Data read for \"\(entity.title)\" returned 0 bytes — skipping upload")
                    continue
                }
                if diskSize > 0 && Int64(data.count) < diskSize / 2 {
                    print("[SupabaseSyncService] ⚠️ Data read for \"\(entity.title)\" (\(data.count) bytes) is far smaller than file (\(diskSize) bytes) — skipping upload")
                    continue
                }

                let ct = SupabaseFileStorageService.contentType(for: ext)
                try await client.storage
                    .from("audio")
                    .upload(
                        remotePath,
                        data:    data,
                        options: FileOptions(contentType: ct, upsert: true)
                    )

                entity.remoteKey           = remotePath
                entity.fileUploaded        = true
                entity.syncStatus          = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[SupabaseSyncService] ✅ Uploaded \"\(entity.title)\" (\(data.count / 1024)KB) → \(remotePath)")

            } catch {
                // Log and skip — will retry on the next sync cycle.
                print("[SupabaseSyncService] ❌ Upload failed for \"\(entity.title)\": \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            // Push again so the server records the updated remoteKey + fileUploaded=true.
            try await pushTracks(userID: userID)
            print("[SupabaseSyncService] ✅ File sync complete — \(tracks.count) file(s) processed")
        } else if missingFileCount > 0 {
            print("[SupabaseSyncService] ⚠️ \(missingFileCount)/\(tracks.count) pending track(s) have missing local files — they cannot be uploaded until the source file is present")
        } else {
            print("[SupabaseSyncService] No pending file uploads")
        }
    }

    private func fetchTracksNeedingUpload() throws -> [TrackEntity] {
        try context.fetch(
            FetchDescriptor<TrackEntity>(
                predicate: #Predicate {
                    $0.fileUploaded == false &&
                    $0.localPath != "" &&
                    $0.isSoftDeleted == false
                }
            )
        )
    }

    // MARK: - Pull

    private func pullAll(userID: UUID) async throws {
        try await pullTracks(userID: userID)
        try await pullAlbums(userID: userID)
        try await pullArtists(userID: userID)
        try await pullPlaylists(userID: userID)
    }

    private func pullTracks(userID: UUID) async throws {
        let since = lastPullDate(table: "tracks", userID: userID)
        let rows: [TrackRow] = try await client
            .from("tracks")
            .select()
            .eq("user_id", value: userID.uuidString)
            .gt("updated_at", value: since)
            .order("updated_at")
            .execute()
            .value

        guard !rows.isEmpty else {
            print("[Sync] ↓ Tracks: nothing new since last pull")
            setLastPullDate(table: "tracks", userID: userID)
            return
        }

        var inserted = 0, updated = 0, skipped = 0
        for row in rows {
            if let existing = try fetchTrackEntity(id: row.id) {
                // CRITICAL: Never overwrite a locally-pending deletion with a stale server record.
                // Check BOTH isSoftDeleted (SwiftData flag) and syncStatus — a SwiftData caching issue
                // can sometimes leave syncStatus readable but isSoftDeleted stale, so both guards are needed.
                if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                    skipped += 1
                    continue
                }
                // Last-Write-Wins — but always apply a server deletion regardless of timestamp
                // to prevent clock-skew from blocking deletes from other devices.
                if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                    row.apply(to: existing)
                    updated += 1
                }
            } else {
                // Don't create a local entity for a server record that's already deleted —
                // there's nothing useful to do with it and it would be invisible to the UI anyway.
                guard !row.isDeleted else { skipped += 1; continue }
                context.insert(TrackEntity(from: row))
                inserted += 1
            }
        }
        try context.save()
        setLastPullDate(table: "tracks", userID: userID)

        print("[Sync] ↓ Tracks: \(inserted) new, \(updated) updated, \(skipped) skipped")
    }

    private func pullAlbums(userID: UUID) async throws {
        let since = lastPullDate(table: "albums", userID: userID)
        let rows: [AlbumRow] = try await client
            .from("albums")
            .select()
            .eq("user_id", value: userID.uuidString)
            .gt("updated_at", value: since)
            .order("updated_at")
            .execute()
            .value

        var inserted = 0, updated = 0
        for row in rows {
            if let existing = try fetchAlbumEntity(id: row.id) {
                if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue { continue }
                if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                    row.apply(to: existing)
                    updated += 1
                }
            } else {
                guard !row.isDeleted else { continue }
                context.insert(AlbumEntity(from: row))
                inserted += 1
            }
        }
        if !rows.isEmpty {
            try context.save()
            print("[Sync] ↓ Albums: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "albums", userID: userID)
    }

    private func pullArtists(userID: UUID) async throws {
        let since = lastPullDate(table: "artists", userID: userID)
        let rows: [ArtistRow] = try await client
            .from("artists")
            .select()
            .eq("user_id", value: userID.uuidString)
            .gt("updated_at", value: since)
            .order("updated_at")
            .execute()
            .value

        var inserted = 0, updated = 0
        for row in rows {
            if let existing = try fetchArtistEntity(id: row.id) {
                if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue { continue }
                if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                    row.apply(to: existing)
                    updated += 1
                }
            } else {
                guard !row.isDeleted else { continue }
                context.insert(ArtistEntity(from: row))
                inserted += 1
            }
        }
        if !rows.isEmpty {
            try context.save()
            print("[Sync] ↓ Artists: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "artists", userID: userID)
    }

    private func pullPlaylists(userID: UUID) async throws {
        let since = lastPullDate(table: "playlists", userID: userID)
        let rows: [PlaylistRow] = try await client
            .from("playlists")
            .select()
            .eq("user_id", value: userID.uuidString)
            .gt("updated_at", value: since)
            .order("updated_at")
            .execute()
            .value

        guard !rows.isEmpty else {
            setLastPullDate(table: "playlists", userID: userID)
            return
        }

        var inserted = 0, updated = 0, skipped = 0
        var favouritesTrackIDs: [UUID]? = nil   // set if Favourites was updated

        for row in rows {
            if let existing = try fetchPlaylistEntity(id: row.id) {
                // All Songs is a locally-derived smart playlist. Never pull it.
                if row.id == Playlist.allSongsID {
                    skipped += 1
                    continue
                }

                // Never overwrite a locally-pending deletion with a stale server record.
                if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                    skipped += 1
                    continue
                }
                // LWW — but always apply server deletion regardless of timestamp.
                if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                    row.apply(to: existing)
                    updated += 1
                    if row.id == Playlist.favouritesID {
                        favouritesTrackIDs = row.trackIDs
                    }
                }
            } else {
                guard !row.isDeleted else { skipped += 1; continue }
                if row.id == Playlist.allSongsID { skipped += 1; continue }
                context.insert(PlaylistEntity(from: row))
                inserted += 1
                if row.id == Playlist.favouritesID {
                    favouritesTrackIDs = row.trackIDs
                }
            }
        }

        try context.save()
        setLastPullDate(table: "playlists", userID: userID)

        // Rebuild FavoriteEntity records if Favourites track_ids changed.
        // This keeps heart state consistent across devices without a separate sync.
        if let ids = favouritesTrackIDs {
            let favRepo = FavoriteRepository(context: context)
            try favRepo.rebuildFromIDs(ids, deviceID: deviceID)
        }

        print("[Sync] ↓ Playlists: \(inserted) new, \(updated) updated, \(skipped) skipped")
    }

    // MARK: - Pending Count

    private func pendingCount() -> Int {
        let tracks    = (try? fetchPendingTracks())?.count    ?? 0
        let albums    = (try? fetchPendingAlbums())?.count    ?? 0
        let artists   = (try? fetchPendingArtists())?.count   ?? 0
        let playlists = (try? fetchPendingPlaylists())?.count ?? 0
        return tracks + albums + artists + playlists
    }

    // MARK: - SwiftData Helpers

    private func fetchPendingPlaylists() throws -> [PlaylistEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.syncStatus != synced })
        ).filter { $0.id != Playlist.allSongsID }
    }

    private func fetchPlaylistEntity(id: UUID) throws -> PlaylistEntity? {
        try context.fetch(
            FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchPendingTracks() throws -> [TrackEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<TrackEntity>(predicate: #Predicate {
                $0.syncStatus != synced &&
                // Never push file-less placeholder tracks — shadow rows created for songs
                // in a *shared* playlist this user doesn't own. They carry the original
                // owner's track id, so upserting them into our `tracks` table violates its
                // RLS USING policy (error 42501). A genuine local import always has a
                // localPath; a previously-synced track keeps its syncServerID, so
                // metadata-only edits still sync.
                ($0.localPath != "" || $0.syncServerID != nil)
            })
        )
    }

    private func fetchPendingAlbums() throws -> [AlbumEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<AlbumEntity>(predicate: #Predicate { $0.syncStatus != synced })
        )
    }

    private func fetchPendingArtists() throws -> [ArtistEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.syncStatus != synced })
        )
    }

    private func fetchTrackEntity(id: UUID) throws -> TrackEntity? {
        try context.fetch(
            FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchAlbumEntity(id: UUID) throws -> AlbumEntity? {
        try context.fetch(
            FetchDescriptor<AlbumEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchArtistEntity(id: UUID) throws -> ArtistEntity? {
        try context.fetch(
            FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func markPending(entityID: UUID) {
        if let entity = try? fetchTrackEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        } else if let entity = try? fetchAlbumEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        } else if let entity = try? fetchArtistEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        }
    }

    // MARK: - Delete All Server Data

    /// Wipes every track/album/artist row AND every audio file for the current
    /// user from Supabase. DB rows are soft-deleted (is_deleted = true, updated_at = now())
    /// so that every other device's incremental pull picks up the change and clears
    /// its local library automatically on the next sync cycle.
    public func deleteAllServerData() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        let uid = userID.uuidString
        let now = iso8601Now()

        print("[Sync] 🗑  Soft-deleting all server data for user \(uid)…")

        // 1. Soft-delete DB rows — set is_deleted = true and bump updated_at so
        //    other devices' incremental pull picks up the change.
        let wipe = WipePayload(updatedAt: now)
        try await client.from("tracks")   .update(wipe).eq("user_id", value: uid).execute()
        print("[Sync] 🗑  Soft-deleted tracks")
        try await client.from("albums")   .update(wipe).eq("user_id", value: uid).execute()
        print("[Sync] 🗑  Soft-deleted albums")
        try await client.from("artists")  .update(wipe).eq("user_id", value: uid).execute()
        print("[Sync] 🗑  Soft-deleted artists")
        try await client.from("playlists").update(wipe).eq("user_id", value: uid).execute()
        print("[Sync] 🗑  Soft-deleted playlists")

        // 2. Hard-delete audio files from Storage (non-fatal if this fails).
        //    Files don't need a deletion signal — once is_deleted propagates, the
        //    library is empty and the orphaned files are unreachable.
        let folder = userID.uuidString.lowercased()
        do {
            let files = try await client.storage.from("audio").list(path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await client.storage.from("audio").remove(paths: paths)
                print("[Sync] 🗑  Deleted \(paths.count) audio file(s) from Storage")
            } else {
                print("[Sync] 🗑  No audio files in Storage for this user")
            }
        } catch {
            print("[Sync] ⚠️  Storage delete failed (non-fatal): \(error)")
        }

        print("[Sync] 🗑  Server wipe complete")
    }

    // MARK: - Reset

    /// Soft-deletes all tracks, albums, and artists for this user on the server.
    /// Playlists are left intact (their trackID arrays will be emptied locally).
    /// Also hard-deletes audio files from Storage.
    public func deleteAllServerTracks() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        try await client.from("tracks") .update(wipe).eq("user_id", value: uid).execute()
        try await client.from("albums") .update(wipe).eq("user_id", value: uid).execute()
        try await client.from("artists").update(wipe).eq("user_id", value: uid).execute()
        print("[Sync] 🗑  Soft-deleted all server tracks/albums/artists for \(uid)")

        // Remove audio files from Storage (non-fatal).
        let folder = uid.lowercased()
        do {
            let files = try await client.storage.from("audio").list(path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await client.storage.from("audio").remove(paths: paths)
                print("[Sync] 🗑  Deleted \(paths.count) audio file(s) from Storage")
            }
        } catch {
            print("[Sync] ⚠️  Storage delete failed (non-fatal): \(error)")
        }
    }

    /// Soft-deletes all user-created playlists on the server.
    /// The two system playlists (All Songs, Favourites) are left untouched.
    public func deleteAllServerUserPlaylists() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        // Exclude the two system playlists by their stable UUIDs.
        try await client.from("playlists")
            .update(wipe)
            .eq("user_id", value: uid)
            .neq("id", value: Playlist.favouritesID.uuidString.lowercased())
            .neq("id", value: Playlist.allSongsID.uuidString.lowercased())
            .execute()
        print("[Sync] 🗑  Soft-deleted all server user playlists for \(uid)")
    }

    /// Clears the stored pull timestamps so the next sync performs a full pull
    /// from the beginning of time. Call this after clearing the local library.
    public func resetSyncTimestamps() {
        guard let userID = currentUser?.id else { return }
        for table in ["tracks", "albums", "artists", "playlists"] {
            UserDefaults.standard.removeObject(forKey: lastPullDateKey(table: table, userID: userID))
        }
        print("[SupabaseSyncService] Sync timestamps reset — next pull will fetch all server records")
    }

    // MARK: - Last Pull Timestamps (per table per user, stored in UserDefaults)

    private func lastPullDateKey(table: String, userID: UUID) -> String {
        "mix.sync.\(table).lastPull.\(userID.uuidString)"
    }

    /// Returns a very old date if we've never pulled, so the first pull fetches everything.
    private func lastPullDate(table: String, userID: UUID) -> String {
        let key = lastPullDateKey(table: table, userID: userID)
        if let stored = UserDefaults.standard.string(forKey: key) {
            // Apply a 24-hour overlap window to catch clock-skewed pushes from other devices.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: stored) {
                let overlapDate = date.addingTimeInterval(-86400) // 24 hours
                return f.string(from: overlapDate)
            }
            return stored
        }
        return "1970-01-01T00:00:00.000Z"
    }

    private func setLastPullDate(table: String, userID: UUID) {
        let key = lastPullDateKey(table: table, userID: userID)
        UserDefaults.standard.set(iso8601Now(), forKey: key)
    }

    private func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Artwork Sync

    private func uploadPendingArtworks(userID: UUID) async throws {
        try await uploadPendingTrackArtworks(userID: userID)
        try await uploadPendingAlbumArtworks(userID: userID)
        try await uploadPendingArtistArtworks(userID: userID)
    }

    private func uploadPendingTrackArtworks(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(tracks.count) track(s) needing artwork upload")
        guard !tracks.isEmpty else { return }

        var uploadedAny = false
        for entity in tracks {
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for track artwork: \(entity.title)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/tracks/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await client.storage
                    .from("artwork")
                    .upload(
                        remotePath,
                        data: compressed,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded track artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for track artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushTracks(userID: userID)
        }
    }

    private func uploadPendingAlbumArtworks(userID: UUID) async throws {
        let albums = try fetchAlbumsNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(albums.count) album(s) needing artwork upload")
        guard !albums.isEmpty else { return }

        var uploadedAny = false
        for entity in albums {
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for album artwork: \(entity.title)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/albums/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await client.storage
                    .from("artwork")
                    .upload(
                        remotePath,
                        data: compressed,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded album artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for album artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushAlbums(userID: userID)
        }
    }

    private func uploadPendingArtistArtworks(userID: UUID) async throws {
        let artists = try fetchArtistsNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(artists.count) artist(s) needing artwork upload")
        guard !artists.isEmpty else { return }

        var uploadedAny = false
        for entity in artists {
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for artist artwork: \(entity.name)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/artists/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await client.storage
                    .from("artwork")
                    .upload(
                        remotePath,
                        data: compressed,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded artist artwork: \(entity.name) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for artist artwork (\(entity.name)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushArtists(userID: userID)
        }
    }

    private func downloadPendingArtworks(userID: UUID) async throws {
        try await downloadPendingTrackArtworks(userID: userID)
        try await downloadPendingAlbumArtworks(userID: userID)
        try await downloadPendingArtistArtworks(userID: userID)
    }

    private func downloadPendingTrackArtworks(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(tracks.count) track(s) needing artwork download")
        guard !tracks.isEmpty else { return }

        var downloadedAny = false
        for entity in tracks {
            guard let key = entity.artworkKey, !key.isEmpty else { continue }

            do {
                let data = try await client.storage
                    .from("artwork")
                    .download(path: key)

                entity.artworkData = data
                downloadedAny = true
                print("[Sync] ↓ Downloaded track artwork: \(entity.title) (\(data.count / 1024)KB) from \(key)")
            } catch {
                print("[Sync] ❌ Download failed for track artwork (\(entity.title)) from \(key): \(error)")
            }
        }

        if downloadedAny {
            try context.save()
        }
    }

    private func downloadPendingAlbumArtworks(userID: UUID) async throws {
        let albums = try fetchAlbumsNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(albums.count) album(s) needing artwork download")
        guard !albums.isEmpty else { return }

        var downloadedAny = false
        for entity in albums {
            guard let key = entity.artworkKey, !key.isEmpty else { continue }

            do {
                let data = try await client.storage
                    .from("artwork")
                    .download(path: key)

                entity.artworkData = data
                downloadedAny = true
                print("[Sync] ↓ Downloaded album artwork: \(entity.title) (\(data.count / 1024)KB) from \(key)")
            } catch {
                print("[Sync] ❌ Download failed for album artwork (\(entity.title)) from \(key): \(error)")
            }
        }

        if downloadedAny {
            try context.save()
        }
    }

    private func downloadPendingArtistArtworks(userID: UUID) async throws {
        let artists = try fetchArtistsNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(artists.count) artist(s) needing artwork download")
        guard !artists.isEmpty else { return }

        var downloadedAny = false
        for entity in artists {
            guard let key = entity.artworkKey, !key.isEmpty else { continue }

            do {
                let data = try await client.storage
                    .from("artwork")
                    .download(path: key)

                entity.artworkData = data
                downloadedAny = true
                print("[Sync] ↓ Downloaded artist artwork: \(entity.name) (\(data.count / 1024)KB) from \(key)")
            } catch {
                print("[Sync] ❌ Download failed for artist artwork (\(entity.name)) from \(key): \(error)")
            }
        }

        if downloadedAny {
            try context.save()
        }
    }

    private func fetchTracksNeedingArtworkUpload() throws -> [TrackEntity] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData != nil }
    }

    private func fetchAlbumsNeedingArtworkUpload() throws -> [AlbumEntity] {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData != nil }
    }

    private func fetchArtistsNeedingArtworkUpload() throws -> [ArtistEntity] {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData != nil }
    }

    private func fetchTracksNeedingArtworkDownload() throws -> [TrackEntity] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData == nil }
    }

    private func fetchAlbumsNeedingArtworkDownload() throws -> [AlbumEntity] {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData == nil }
    }

    private func fetchArtistsNeedingArtworkDownload() throws -> [ArtistEntity] {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false
            }
        )
        return try context.fetch(descriptor).filter { $0.artworkData == nil }
    }

    // MARK: - Artwork Compression Helper

    private func compressArtwork(data: Data, maxDimension: CGFloat = 300) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let outputData = NSMutableData()
        let type = "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, type, 1, nil) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]

        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputData as Data
    }
}

// MARK: - Helpers

/// Payload used by deleteAllServerData() to soft-delete all rows for a user.
private struct WipePayload: Encodable {
    let isDeleted: Bool   = true
    let updatedAt: String
    enum CodingKeys: String, CodingKey {
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
    }
}
