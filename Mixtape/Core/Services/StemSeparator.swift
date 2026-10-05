// Splits a song into vocals, drums, bass and other for the Mac studio, on this Mac (Demucs on MLX).
// The model (about 170 MB) downloads on first use. Stems are kept for the last few songs.

import Foundation
#if canImport(DemucsMLX) && arch(arm64)
import DemucsMLX
import MLX
#endif

nonisolated enum StemSeparator {

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Stems need a Mac with Apple silicon." }
    }

    /// False on iPhone and Intel Macs.
    static var isAvailable: Bool {
        #if canImport(DemucsMLX) && arch(arm64)
        true
        #else
        false
        #endif
    }

    private static let model = "htdemucs"
    /// Pinned so an upstream change can't swap the weights under saved edits.
    private static let weights = URL(string:
        "https://huggingface.co/iky1e/demucs-mlx/resolve/3ff2e582c1456c6a03a077b6e47254e0ba41bdcf/")!
    private static let keep = 3

    private static var modelDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Mixtape/Models/\(model)", directoryHint: .isDirectory)
    }

    private static func folder(for id: UUID) -> URL {
        URL.cachesDirectory.appending(path: "Stems/\(id.uuidString)", directoryHint: .isDirectory)
    }

    /// Stem files for the song `id`, if they've been made.
    static func cached(for id: UUID) -> [String: URL]? {
        let dir = folder(for: id)
        let files = Dictionary(uniqueKeysWithValues: SongEdit.stemNames.map { ($0, dir.appending(path: "\($0).m4a")) })
        guard files.values.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return files
    }

    /// The stems of `source` (the song `id`), separating it unless they're cached. `progress` gets 0-1,
    /// the model download included the first time.
    @concurrent static func stems(of source: URL, id: UUID,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> [String: URL] {
        if let files = cached(for: id) { return files }
        #if canImport(DemucsMLX) && arch(arm64)
        // Hardware acceleration off splits on the CPU, a lot slower. The scoped API is task-local and
        // Demucs runs on its own queue, so this sets the default before MLX makes anything.
        if !HardwareAcceleration.isOn { Device.setDefault(device: .cpu) }
        let fm = FileManager.default
        let modelFile = modelDirectory.appending(path: "\(model).safetensors")
        let share = fm.fileExists(atPath: modelFile.path) ? 0.0 : 0.3
        if share > 0 {
            try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try await download("\(model)_config.json", to: modelDirectory) { _ in }
            try await download("\(model).safetensors", to: modelDirectory) { progress($0 * share) }
        }

        // MLX keeps its buffers cached (about 5 GB after one song) until told otherwise.
        // The scope below lets the model and its arrays go first.
        defer { Memory.clearCache() }
        do {
            let separator = try DemucsSeparator(modelName: model, modelDirectory: modelDirectory)
            let token = DemucsCancelToken()
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { done in
                    separator.separate(fileAt: source, cancelToken: token, progress: { p in
                        progress(share + (1 - share) * Double(p.fraction))
                    }, completion: { done.resume(with: $0) })
                }
            } onCancel: { token.cancel() }
            try Task.checkCancellation()

            // Written beside and moved in, so a half-written set never looks cached.
            let dir = folder(for: id)
            let temp = dir.deletingLastPathComponent().appending(path: "\(id.uuidString)-\(UUID().uuidString)")
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            for name in SongEdit.stemNames {
                guard let audio = result.stems[name] else { throw Unavailable() }
                try AudioIO.writeAudio(audio, to: temp.appending(path: "\(name).m4a"), format: .alac)
            }
            try? fm.removeItem(at: dir)
            try fm.moveItem(at: temp, to: dir)
        }
        prune()
        guard let files = cached(for: id) else { throw Unavailable() }
        return files
        #else
        throw Unavailable()
        #endif
    }

    /// Keeps the `keep` most recently used songs' stems.
    private static func prune() {
        let root = URL.cachesDirectory.appending(path: "Stems", directoryHint: .isDirectory)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let byAge = dirs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for dir in byAge.dropFirst(keep) { try? FileManager.default.removeItem(at: dir) }
    }

    private static func download(_ name: String, to dir: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let relay = ProgressRelay(progress)
        let (temp, response) = try await URLSession.shared.download(from: weights.appending(path: name), delegate: relay)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unavailable() }
        let dest = dir.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let handler: @Sendable (Double) -> Void
        var observation: NSKeyValueObservation?
        init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [handler] p, _ in handler(p.fractionCompleted) }
        }
    }
}

extension SongEdit {
    /// This device has the studio parts the edit needs: stems want Apple silicon, arranging the Mac.
    var studioReady: Bool { (stems == nil || StemSeparator.isAvailable) && (!isArranged || Self.canArrange) }
}

extension Track {
    /// Edit Song… shows for songs with audio; a studio edit only where it can be remade.
    var canEdit: Bool { canResolveAudio && edit?.studioReady != false }
}
