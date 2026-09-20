// ArtworkCompaction.swift
// Mixtape — Core/Services
//
// One-shot repair for artwork written before covers were downsampled on the way
// in.
//
// Every cover now passes through `ImageDownsampler.artworkJPEG` before it is
// stored, so nothing new is oversized. Rows written before that change still
// hold whatever the source gave us — an embedded MP3 cover is routinely 1–3 MB,
// a catalogue download not much less — and there are four of them per song once
// the album and artist rows are counted. That is the bulk of an oversized
// library store, and no amount of care at the write site reaches it.
//
// Deliberately *not* a schema migration. Nothing about the shape of the data
// changes: the same attribute keeps the same kind of value, only smaller. A
// `SchemaMigrationPlan` stage would have to run before the store opens, on the
// main thread, with the whole library blocked behind it.

import Foundation
import SwiftData
import CoreGraphics
import OSLog

/// Re-encodes artwork already in the store down to the size new artwork is
/// written at. Runs once per device, in the background, and can be cancelled.
@MainActor
public final class ArtworkCompaction {

    /// Bumping the suffix re-runs the pass on every device. Only worth doing if
    /// `ImageDownsampler.artworkMaxDimension` drops again.
    private static let didRunKey = "mixtape.artworkCompaction.v1"

    /// Rows re-encoded between saves.
    ///
    /// Small on purpose. The batch is the peak: every blob in it is resident at
    /// once, and at pre-compaction sizes fifty of them is already a couple of
    /// hundred megabytes. Small batches also mean an interrupted pass keeps
    /// nearly all of its work.
    private static let batchSize = 40

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    private var task: Task<Void, Never>?

    public init() {}

    /// Starts the pass unless it has already run on this device.
    ///
    /// Returns immediately; the work happens on the returned task's own time.
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

    /// Stops a pass in progress. Whatever it had already saved stays saved, and
    /// the "done" marker is not written, so the next launch resumes — the rows
    /// it got through are simply skipped as already small.
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

    /// Walks one entity type in batches, returning the bytes reclaimed.
    ///
    /// `sortedBy` only has to be stable, not meaningful: the pass pages with
    /// `fetchOffset`, and a row it rewrites still matches the predicate and
    /// still sorts where it did, so the offsets stay honest as it goes.
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

            // Only rows worth the work. `artworkJPEG` passes anything already
            // under the threshold straight back, so re-encoding those would be
            // pure cost for a guaranteed no-op.
            let oversized = batch.enumerated().compactMap { index, row -> (Int, Data)? in
                guard let data = get(row), data.count > ImageDownsampler.artworkPassthroughBytes else { return nil }
                return (index, data)
            }
            if oversized.isEmpty { continue }

            // Off the main actor: this is ImageIO decode + JPEG encode, tens of
            // milliseconds a cover, and doing it inline would drop frames for
            // as long as the pass ran. `ImageDownsampler` is `nonisolated`
            // precisely so this hop is available.
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
                // Only `artworkData` is touched. Not `artworkKey`, and not the
                // sync metadata: the server's copy is unchanged and this device
                // has nothing new to tell anyone. Marking these rows modified
                // would queue the entire library for a pointless re-upload.
                set(batch[index], smaller)
                reclaimed += original.count - smaller.count
                rewritten += 1
            }

            do {
                try context.save()
            } catch {
                print("[ArtworkCompaction] save failed at offset \(offset): \(error)")
                break
            }

            // Let the UI draw. Without this the batches run back-to-back on the
            // main actor and the app is unresponsive for the whole pass — the
            // same failure as the import loop that reported progress it was
            // blocking the redraw of.
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
        print(line)
        MixLog.database.notice("\(line, privacy: .public)")
    }
}
