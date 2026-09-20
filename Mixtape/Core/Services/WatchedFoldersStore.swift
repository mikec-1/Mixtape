// WatchedFoldersStore.swift
// Mixtape — Core/Services
//
// The folders on this device that the user has asked Mixtape to look in.
//
// This is deliberately *not* the export folder. Mixtape writes to the export
// folder, which is what made scanning it such a bad idea: a copy Mixtape wrote
// looks exactly like new music to a scanner, so "Sync" could resurrect songs
// the user had deleted on another device. A watched folder is the opposite —
// Mixtape never writes to one, so everything found in it is, by definition,
// the user's own file that they put there themselves.
//
// Folders are held as security-scoped bookmarks rather than paths so they
// survive a rename or a move, and so a folder picked on iOS stays reachable
// after relaunch. macOS isn't sandboxed today, where the scope calls are
// harmless no-ops; iOS very much needs them.

import Foundation
import Combine
import SwiftUI

// MARK: - Model

/// One folder the user has added, as stored.
public struct WatchedFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// Bookmark data — the durable reference. The path below is a label.
    public var bookmark: Data
    /// Last known path, for display and for a fallback when the bookmark
    /// cannot be resolved (an unplugged drive, a folder deleted outright).
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

    /// Scopes opened this launch, kept open until the process ends.
    ///
    /// A security-scoped URL has to stay open for as long as anything may read
    /// through it, and "anything" here includes an AVPlayer that holds the file
    /// for the length of a song. Balancing each start with a stop at the end of
    /// a scan would pull the floor out from under playback, so the scope is
    /// opened once per folder per launch and released when the app exits.
    private var openScopes: [UUID: URL] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    /// Every watched folder that can actually be reached right now, paired with
    /// its live URL. A folder whose bookmark no longer resolves is skipped, not
    /// removed: an external drive comes back when it is plugged in again, and
    /// deleting the user's setting because a disk was unmounted would be rude.
    public func resolvedFolders() -> [(folder: WatchedFolder, url: URL)] {
        folders.compactMap { folder in
            guard let url = resolve(folder) else { return nil }
            return (folder, url)
        }
    }

    public var isEmpty: Bool { folders.isEmpty }

    // MARK: Editing

    /// Adds a folder. Adding one already in the list is a no-op rather than an
    /// error — the user has said what they want either way.
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
            // Fall back to the recorded path. Unsandboxed macOS reads it fine,
            // and a readable folder is better than a folder the user has to add
            // again because its bookmark went bad.
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
