// Re-encodes downloads to AAC for the offline store. AAC rather than Opus
// because AVFoundation can't decode Opus. AVAssetWriter rather than ffmpeg
// because iOS can't run Process.

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Quality

/// How much disk a download is allowed to take.
public enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {

    case high
    /// AAC-LC, 96 kbps.
    case normal
    /// HE-AAC, 64 kbps.
    case low

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .high:   return "High"
        case .normal: return "Normal"
        case .low:    return "Low"
        }
    }

    public var detail: String {
        switch self {
        case .high:   return "Original file, as the source served it."
        case .normal: return "AAC 96 kbps — about half the size."
        case .low:    return "HE-AAC 64 kbps — smallest downloads."
        }
    }

    /// Target bit rate, nil keeps the original.
    var bitRate: Int? {
        switch self {
        case .high:   return nil
        case .normal: return 96_000
        case .low:    return 64_000
        }
    }

    /// LC at 96k, HE-AAC at 64k since LC degrades below ~80k.
    var formatID: AudioFormatID? {
        switch self {
        case .high:   return nil
        case .normal: return kAudioFormatMPEG4AAC
        case .low:    return kAudioFormatMPEG4AAC_HE
        }
    }

    /// One step down, for "auto adjust" on a metered connection.
    public var loweredForCellular: DownloadQuality {
        switch self {
        case .high:   return .normal
        case .normal: return .low
        case .low:    return .low
        }
    }
}

// MARK: - Transcoder

public enum AudioTranscoder {

    public enum TranscodeError: LocalizedError {
        case noAudioTrack
        case unsupportedQuality
        case cannotConfigure
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack:       return "That file has no audio track."
            case .unsupportedQuality: return "That quality doesn't re-encode."
            case .cannotConfigure:    return "Couldn't set up the encoder."
            case .failed(let why):    return why
            }
        }
    }

    /// Always writes an .m4a. Throws so the caller can fall back to the original.
    static func transcode(_ source: URL,
                          to destination: URL,
                          quality: DownloadQuality) async throws {

        guard let bitRate = quality.bitRate, let formatID = quality.formatID else {
            throw TranscodeError.unsupportedQuality
        }

        let asset = AVURLAsset(url: source)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.noAudioTrack
        }

        // Keep the source's channel count.
        var channels   = 2
        var sampleRate = 44_100.0
        if let description = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if asbd.mChannelsPerFrame > 0 { channels   = Int(asbd.mChannelsPerFrame) }
            if asbd.mSampleRate      > 0 { sampleRate = asbd.mSampleRate }
        }
        // Cap at stereo.
        channels = min(channels, 2)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw TranscodeError.cannotConfigure }
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey:         formatID,
            AVSampleRateKey:       sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey:   bitRate,
            AVChannelLayoutKey:    Data(bytes: &layout,
                                        count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscodeError.cannotConfigure }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw TranscodeError.failed(
                writer.error?.localizedDescription
                ?? reader.error?.localizedDescription
                ?? "Couldn't start encoding."
            )
        }
        writer.startSession(atSourceTime: .zero)

        try await pump(reader: reader, writer: writer, input: input, output: output)
    }

    private static func pump(reader: AVAssetReader,
                             writer: AVAssetWriter,
                             input:  AVAssetWriterInput,
                             output: AVAssetReaderTrackOutput) async throws {

        let queue = DispatchQueue(label: "mix.transcode")
        // Only touched from `queue` and the finish handler, in order.
        nonisolated(unsafe) let reader = reader, writer = writer, input = input, output = output
        // Guards against resuming the continuation twice.
        let resumed = OneShot()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !resumed.isSet else { return }

                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()

                        // Treat a failed read as an error, not a short file.
                        if reader.status == .failed {
                            guard resumed.claim() else { return }
                            writer.cancelWriting()
                            continuation.resume(throwing: TranscodeError.failed(
                                reader.error?.localizedDescription ?? "Read failed."))
                            return
                        }

                        writer.finishWriting {
                            guard resumed.claim() else { return }
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: TranscodeError.failed(
                                    writer.error?.localizedDescription ?? "Write failed."))
                            }
                        }
                        return
                    }

                    if !input.append(buffer) {
                        guard resumed.claim() else { return }
                        reader.cancelReading()
                        input.markAsFinished()
                        writer.cancelWriting()
                        continuation.resume(throwing: TranscodeError.failed(
                            writer.error?.localizedDescription ?? "Encoding failed."))
                        return
                    }
                }
            }
        }
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        /// Sets the latch and reports whether this caller was the one to set it.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !value else { return false }
            value = true
            return true
        }
    }
}
