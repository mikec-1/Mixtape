// FileAuthLocalStorage.swift
// Mixtape — Core/Services
//
// A Supabase `AuthLocalStorage` that persists the auth session to a file in
// Application Support instead of the macOS Keychain.
//
// Why: the default `KeychainLocalStorage` triggers a recurring
// "Mixtape wants to access key supabase.gotrue.swift in your keychain"
// password prompt — on first launch and after every update. The cause is our
// ad-hoc code signature: it changes on every build, so the keychain's
// per-item ACL no longer recognizes the app and macOS re-prompts. A plain file
// has no such ACL, so the prompt never appears. The session is written to a
// 0600 file in the user's container, readable only by their account.

import Foundation
import Supabase  // re-exports Auth (AuthLocalStorage)

final class FileAuthLocalStorage: AuthLocalStorage {

    private let directory: URL
    private let fileManager = FileManager.default
    // Serialize access so concurrent store/retrieve/remove can't race on disk.
    private let queue = DispatchQueue(label: "com.mixtape.fileauthstorage")

    init() {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Auth", isDirectory: true)
    }

    private func fileURL(for key: String) -> URL {
        // Keys (e.g. "supabase.gotrue.swift") are filesystem-safe, but guard
        // defensively against path separators just in case.
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe)
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func store(key: String, value: Data) throws {
        try queue.sync {
            try ensureDirectory()
            let url = fileURL(for: key)
            try value.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func retrieve(key: String) throws -> Data? {
        try queue.sync {
            let url = fileURL(for: key)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    func remove(key: String) throws {
        try queue.sync {
            let url = fileURL(for: key)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }
}
