// ModelContainerSetup.swift
// Mixtape — Data Layer
//
// Single place to configure and vend the SwiftData ModelContainer.
// The container is created once in AppDependencies and injected via .modelContainer().

import Foundation
import SwiftData

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

    /// Call this once at app startup. Crashes on failure (unrecoverable — bad schema).
    public static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[ModelContainerSetup] ⚠️ Failed to load ModelContainer (probably schema migration issue): \(error)")
            print("[ModelContainerSetup] 🗑️ Wiping local SQLite store to recover...")

            let fm = FileManager.default
            let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let storeURL = appSupportDir?.appendingPathComponent("default.store") {
                let shmURL = storeURL.deletingLastPathComponent().appendingPathComponent("default.store-shm")
                let walURL = storeURL.deletingLastPathComponent().appendingPathComponent("default.store-wal")
                try? fm.removeItem(at: storeURL)
                try? fm.removeItem(at: shmURL)
                try? fm.removeItem(at: walURL)
            }

            // Reset all sync timestamps to trigger a clean full sync from Supabase
            let defaults = UserDefaults.standard
            let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("mix.sync.") }
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
