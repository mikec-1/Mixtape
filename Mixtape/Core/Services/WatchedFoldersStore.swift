// Folders the user asked Mixtape to watch on this device. Not the export
// folder: Mixtape never writes here, so everything found is the user's.
// Stored as security-scoped bookmarks so they survive moves and iOS relaunches
// (no-ops on unsandboxed macOS).

import Foundation
import Combine
import SwiftUI

// MARK: - Model

/// One folder the user has added, as stored.
public struct WatchedFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The durable reference; the path is just a label.
    public var bookmark: Data
    /// Last known path, for display and as a fallback when the bookmark fails.
    public var lastKnownPath: String

    public var displayName: String { (lastKnownPath as NSString).lastPathComponent }

    public init(id: UUID = UUID(), bookmark: Data, lastKnownPath: String) {
        self.id            = id
        self.bookmark      = bookmark
        self.lastKnownPath = lastKnownPath
    }
}

// MARK: - Store

@MainActor
public final class WatchedFoldersStore: ObservableObject {

    @Published public private(set) var folders: [WatchedFolder] = []

    private let defaults: UserDefaults
    private static let key = "localFiles.watchedFolders.v1"

    /// Scopes opened this launch and kept open (AVPlayer may read a file for a
    /// whole song). Released at exit.
    private var openScopes: [UUID: URL] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    /// Reachable watched folders with live URLs. Unresolvable ones are skipped,
    /// not removed (e.g. an unplugged drive).
    public func resolvedFolders() -> [(folder: WatchedFolder, url: URL)] {
        folders.compactMap { folder in
            guard let url = resolve(folder) else { return nil }
            return (folder, url)
        }
    }

    public var isEmpty: Bool { folders.isEmpty }

    // MARK: Editing

    /// Adds a folder. No-op if already present.
    @discardableResult
    public func add(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard !folders.contains(where: { $0.lastKnownPath == path }) else { return false }
        guard let bookmark = makeBookmark(for: url) else { return false }
        folders.append(WatchedFolder(bookmark: bookmark, lastKnownPath: path))
        save()
        return true
    }

    public func remove(id: UUID) {
        if let url = openScopes.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        folders.removeAll { $0.id == id }
        save()
    }

    // MARK: Bookmarks

    private func makeBookmark(for url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
        #else
        return try? url.bookmarkData(options: .minimalBookmark,
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
        #endif
    }

    private func resolve(_ folder: WatchedFolder) -> URL? {
        if let open = openScopes[folder.id] { return open }

        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark,
                                 options: options,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            // Fall back to the recorded path; unsandboxed macOS can read it.
            let fallback = URL(fileURLWithPath: folder.lastKnownPath)
            return FileManager.default.fileExists(atPath: folder.lastKnownPath) ? fallback : nil
        }

        _ = url.startAccessingSecurityScopedResource()
        openScopes[folder.id] = url

        if stale, let fresh = makeBookmark(for: url),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark      = fresh
            folders[index].lastKnownPath = url.standardizedFileURL.path(percentEncoded: false)
            save()
        }
        return url
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([WatchedFolder].self, from: data)
        else { return }
        folders = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
