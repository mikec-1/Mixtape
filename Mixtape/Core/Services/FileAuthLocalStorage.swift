// Stores the Supabase session in a 0600 file in Application Support instead of
// the Keychain. Ad-hoc signing changes every build, so the Keychain would prompt
// for access after every update.

import Foundation
import Supabase  // re-exports Auth (AuthLocalStorage)

final class FileAuthLocalStorage: AuthLocalStorage {

    private let directory: URL
    private var fileManager: FileManager { .default }
    // Serialize access so concurrent store/retrieve/remove can't race on disk.
    private let queue = DispatchQueue(label: "com.mixtape.fileauthstorage")

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Auth", isDirectory: true)
    }

    private func fileURL(for key: String) -> URL {
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
