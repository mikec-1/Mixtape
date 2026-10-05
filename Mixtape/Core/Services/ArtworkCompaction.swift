// One-time pass that shrinks artwork stored before covers were downsampled.
// Not a schema migration because the shape doesn't change.

import Foundation
import SwiftData
import CoreGraphics
import OSLog

/// Runs once per device in the background. Cancellable.
@MainActor
public final class ArtworkCompaction {

    /// Bump to re-run on every device.
    private static let didRunKey = "mixtape.artworkCompaction.v1"

    /// Small batches keep peak memory down and save progress often.
    private static let batchSize = 40

    /// Never stored, see ModelStore.
    private var context: ModelContext { ModelStore.shared.context }
    private var task: Task<Void, Never>?

    public init() {}

    /// No-op if it already ran on this device.
    public func startIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didRunKey) else {
            MixLog.database.notice("Artwork compaction already done on this device")
            return
        }
        guard task == nil else { return }
        MixLog.database.notice("Artwork compaction starting")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Saved batches stay saved. The next launch resumes.
    public func cancel() {
        guard task != nil else { return }
        MixLog.database.notice("Artwork compaction cancelled")
        task?.cancel()
        task = nil
    }

    // MARK: - The pass

    private func run() async {
        let started = Date()
        var reclaimed = 0
        var rewritten = 0

        let trackPass = await compact(TrackEntity.self, sortedBy: SortDescriptor(\.dateImported),
                                    get: { $0.artworkData }, set: { $0.artworkData = $1 })
        reclaimed += trackPass.reclaimed; rewritten += trackPass.rewritten
        guard !Task.isCancelled else { return finish(cancelled: true, rewritten: rewritten, reclaimed: reclaimed, started: started) }

        let albumPass = await compact(AlbumEntity.self, sortedBy: SortDescriptor(\.title),
                                    get: { $0.artworkData }, set: { $0.artworkData = $1 })
        reclaimed += albumPass.reclaimed; rewritten += albumPass.rewritten
        guard !Task.isCancelled else { return finish(cancelled: true, rewritten: rewritten, reclaimed: reclaimed, started: started) }

        let artistPass = await compact(ArtistEntity.self, sortedBy: SortDescriptor(\.name),
                                    get: { $0.artworkData }, set: { $0.artworkData = $1 })
        reclaimed += artistPass.reclaimed; rewritten += artistPass.rewritten
        guard !Task.isCancelled else { return finish(cancelled: true, rewritten: rewritten, reclaimed: reclaimed, started: started) }

        let playlistPass = await compact(PlaylistEntity.self, sortedBy: SortDescriptor(\.dateCreated),
                                    get: { $0.artworkData }, set: { $0.artworkData = $1 })
        reclaimed += playlistPass.reclaimed; rewritten += playlistPass.rewritten
        guard !Task.isCancelled else { return finish(cancelled: true, rewritten: rewritten, reclaimed: reclaimed, started: started) }

        UserDefaults.standard.set(true, forKey: Self.didRunKey)
        finish(cancelled: false, rewritten: rewritten, reclaimed: reclaimed, started: started)
    }

    /// Walks one entity type in batches, returning bytes reclaimed.
    private func compact<T: PersistentModel>(
        _ type: T.Type,
        sortedBy sort: SortDescriptor<T>,
        get: @escaping (T) -> Data?,
        set: (T, Data) -> Void
    ) async -> (reclaimed: Int, rewritten: Int) {
        var offset = 0
        var reclaimed = 0
        var rewritten = 0

        while !Task.isCancelled {
            var descriptor = FetchDescriptor<T>(sortBy: [sort])
            descriptor.fetchLimit  = Self.batchSize
            descriptor.fetchOffset = offset
            guard let batch = try? context.fetch(descriptor), !batch.isEmpty else { break }
            offset += batch.count

            // artworkJPEG returns small blobs unchanged, so skip them.
            let oversized = batch.enumerated().compactMap { index, row -> (Int, Data)? in
                guard let data = get(row), data.count > ImageDownsampler.artworkPassthroughBytes else { return nil }
                return (index, data)
            }
            if oversized.isEmpty { continue }

            // Re-encode off the main actor.
            let blobs = oversized.map(\.1)
            let shrunk: [Data?] = await Task.detached(priority: .utility) {
                blobs.map { original in
                    guard let smaller = ImageDownsampler.artworkJPEG(from: original),
                          smaller.count < original.count else { return nil }
                    return smaller
                }
            }.value

            guard !Task.isCancelled else { break }

            for (position, (index, original)) in oversized.enumerated() {
                guard let smaller = shrunk[position] else { continue }
                // Only artworkData changes. Touching sync metadata would re-upload everything.
                set(batch[index], smaller)
                reclaimed += original.count - smaller.count
                rewritten += 1
            }

            do {
                try context.save()
            } catch {
                MixLog.database.error("[ArtworkCompaction] save failed at offset \(offset): \(error)")
                break
            }

            // Let the UI draw between batches.
            await Task.yield()
        }

        MixLog.database.notice("Artwork compaction pass \(String(describing: T.self), privacy: .public): scanned \(offset, privacy: .public) rows, rewrote \(rewritten, privacy: .public), reclaimed \(reclaimed / 1024, privacy: .public) KB")
        return (reclaimed, rewritten)
    }

    private func finish(cancelled: Bool, rewritten: Int, reclaimed: Int, started: Date) {
        let mb      = Double(reclaimed) / 1_048_576
        let seconds = Date().timeIntervalSince(started)
        let verb    = cancelled ? "stopped after" : "done —"
        let line = String(format: "[ArtworkCompaction] %@ %d covers re-encoded, %.1f MB reclaimed in %.1fs",
                          verb, rewritten, mb, seconds)
        MixLog.database.notice("\(line, privacy: .public)")
    }
}
