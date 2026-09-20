// ModelContainerSetup.swift
// Mixtape — Data Layer
//
// Single place to configure and vend the SwiftData ModelContainer.
// One store per account; `ModelStore` owns which one is open.

import Foundation
import SwiftData
import OSLog

public enum ModelContainerSetup {

    /// All @Model types that must be registered with the container.
    static let schema = Schema([
        TrackEntity.self,
        AlbumEntity.self,
        ArtistEntity.self,
        PlaylistEntity.self,
        PlayHistoryEntity.self,
        FavoriteEntity.self,
        SmartPlaylistEntity.self,
        PlayedTrackSnapshotEntity.self,
    ])

    /// Versioned schema for future migrations.
    static let schemaVersion = Schema.Version(1, 0, 0)

    // MARK: - Production Container

    /// Where an account's rows live. Naming and moves live in `StoreFileLayout`.
    static func storeURL(for owner: UUID?) -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return StoreFileLayout.storeURL(for: owner, in: dir)
    }

    /// Call this once per account, through `ModelStore`. Crashes only if a
    /// freshly-wiped store also fails to open (unrecoverable — bad schema).
    public static func makeContainer(for owner: UUID? = nil) -> ModelContainer {
        guard let url = storeURL(for: owner) else {
            // No Application Support directory at all. Nothing sensible is left
            // to do but let SwiftData pick, which is the pre-Phase-4 behaviour.
            return open(ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, allowsSave: true),
                        wiping: nil, owner: owner)
        }
        if StoreFileLayout.adoptSharedStore(at: url, owner: owner) {
            print("[ModelContainerSetup] 📦 Adopted the shared store as \(url.lastPathComponent)")
        }
        return open(ModelConfiguration(schema: schema, url: url, allowsSave: true),
                    wiping: url, owner: owner)
    }

    private static func open(_ config: ModelConfiguration, wiping url: URL?, owner: UUID?) -> ModelContainer {
        do {
            return try MixSignpost.database.interval("open-store") {
                let container = try ModelContainer(for: schema, configurations: [config])
                MixLog.database.notice("Store opened")
                return container
            }
        } catch {
            print("[ModelContainerSetup] ⚠️ Failed to load ModelContainer (probably schema migration issue): \(error)")
            print("[ModelContainerSetup] 🗑️ Wiping local SQLite store to recover...")

            if let url { StoreFileLayout.remove(storeAt: url) }

            // Reset this account's sync timestamps so the empty store is rebuilt
            // from Supabase. Only this one: the other accounts' files on this
            // device were never opened, so their watermarks are still honest.
            let defaults = UserDefaults.standard
            let keys = defaults.dictionaryRepresentation().keys.filter { key in
                guard key.hasPrefix("mix.sync.") else { return false }
                guard let owner else { return true }
                return key.hasSuffix(owner.uuidString)
            }
            for key in keys {
                defaults.removeObject(forKey: key)
            }

            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to recreate ModelContainer after wiping local store: \(error)")
            }
        }
    }

    // MARK: - In-Memory Container (Previews + Tests)

    /// Ephemeral container — data is discarded when the process exits.
    public static func makePreviewContainer() -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create preview ModelContainer: \(error)")
        }
    }
}

// MARK: - UUID Array Codable Helpers
// SwiftData can't store [UUID] directly; we encode as JSON Data.

extension Array where Element == UUID {
    func toData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

extension Data {
    func toUUIDArray() -> [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: self)) ?? []
    }
}
