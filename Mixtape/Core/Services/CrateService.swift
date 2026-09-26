// Crates. Synced in `user_metadata.crates`, like `SavedAlbumsService`, so
// there's no table: a crate is a short list of references.

import Foundation
import Combine

@MainActor
public final class CrateService: ObservableObject {

    public static let shared = CrateService()

    @Published public private(set) var crates: [Crate] = []

    /// Asks the root for a name. A context menu is gone before its alert could show.
    public struct NewCrateRequest { public var item: CrateItem? }
    @Published public var newCrateRequest: NewCrateRequest?

    public var pushWriter: ((String) -> Void)?

    private static let key = "library.crates"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key) { crates = Self.decode(raw) }

        // A wipe takes the crates with it. An account switch swaps them in `accountDidChange`.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let reset = UserDataReset.from(note)
                guard reset.clearedLibrary, !reset.isAccountSwitch, let self, !self.crates.isEmpty else { return }
                self.crates = []
                self.persist()
            }
        }
    }

    // MARK: - Reading

    public func crate(id: UUID) -> Crate? { crates.first { $0.id == id } }

    public func contains(_ item: CrateItem, in crateID: UUID) -> Bool {
        crate(id: crateID)?.items.contains { $0.identity == item.identity } ?? false
    }

    /// Library rows for the crate's items, in order. Covers pass a `limit`: each lookup scans the library.
    public func entries(of crate: Crate, in library: LibraryService, limit: Int = .max) -> [CrateEntry] {
        Array(crate.items.lazy.compactMap { item -> CrateEntry? in
            switch item.kind {
            case .playlist:
                return UUID(uuidString: item.key).flatMap { library.playlist(id: $0) }.map { .playlist($0) }
            case .album:
                return library.album(title: item.key, artistName: item.artist ?? "").map { .album($0) } ?? .online(item)
            case .artist:
                return library.artist(named: item.key).map { .artist($0) } ?? .online(item)
            }
        }.prefix(limit))
    }

    // MARK: - Writing

    public func requestNewCrate(with item: CrateItem? = nil) {
        newCrateRequest = NewCrateRequest(item: item)
    }

    @discardableResult
    public func create(named name: String, with item: CrateItem? = nil) -> Crate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let crate = Crate(id: UUID(),
                          name: trimmed.isEmpty ? "New Crate" : trimmed,
                          items: item.map { [$0] } ?? [],
                          dateCreated: Date())
        crates.append(crate)
        persist()
        return crate
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    public func delete(_ id: UUID) {
        crates.removeAll { $0.id == id }
        persist()
    }

    public func toggle(_ item: CrateItem, in crateID: UUID) {
        if contains(item, in: crateID) { remove(item, from: crateID) } else { update(crateID) { $0.items.append(item) } }
    }

    public func remove(_ item: CrateItem, from crateID: UUID) {
        update(crateID) { $0.items.removeAll { $0.identity == item.identity } }
    }

    private func update(_ id: UUID, _ change: (inout Crate) -> Void) {
        guard let i = crates.firstIndex(where: { $0.id == id }) else { return }
        change(&crates[i])
        persist()
    }

    // MARK: - Sync

    public func adoptRemote(_ raw: String?) {
        guard let raw else { return }
        let remote = Self.decode(raw)
        guard remote != crates else { return }
        crates = remote
        UserDefaults.standard.set(raw, forKey: Self.key)
    }

    /// Swaps in the new account's crates. Not pushed, or it would overwrite theirs.
    public func accountDidChange(remote raw: String?) {
        crates = raw.map(Self.decode) ?? []
        UserDefaults.standard.set(raw, forKey: Self.key)
    }

    private func persist() {
        let raw = Self.encode(crates)
        UserDefaults.standard.set(raw, forKey: Self.key)
        pushWriter?(raw)
    }

    static func encode(_ c: [Crate]) -> String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        return (try? enc.encode(c)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decode(_ raw: String) -> [Crate] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Crate].self, from: Data(raw.utf8))) ?? []
    }
}
