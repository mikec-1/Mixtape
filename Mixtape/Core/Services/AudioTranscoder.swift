// AudioTranscoder.swift
// Mixtape — Core/Services
//
// Re-encodes a song on its way into the offline store.
//
// Downloads used to land as whatever byte-for-byte file the source handed over
// — typically a ~185 kbps MP3 from Supabase, or a 128 kbps AAC from the online
// resolver. That's fine for sixteen songs and ruinous for six thousand: the
// same library Spotify keeps offline in 10 GB was costing about 25 GB here.
//
// So a download now has a quality, and anything below `.high` is re-encoded to
// AAC before it's filed. Two things follow from that choice:
//
//   • AAC, not Opus. Opus is the better codec at these bitrates by a wide
//     margin, and the online resolver can even serve it natively — but nothing
//     in AVFoundation decodes it, and the playback path is built on
//     AVAudioEngine. Shipping a decoder to save a few hundred megabytes isn't
//     the trade.
//   • AVAssetReader/Writer, not ffmpeg. ffmpeg is already bundled, but it runs
//     through `Process`, which doesn't exist on iOS. This encodes identically on
//     both platforms with no binary to ship.
//
// This is a lossy→lossy re-encode. Nothing here pretends otherwise: `.high`
// exists precisely so anyone who cares can opt out, and the original always
// remains on the server to re-download from.

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Quality

/// How much disk a download is allowed to take.
public enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {

    /// No re-encode — the file is filed exactly as it arrived.
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

    /// One line of plain English for the pickers — the size/fidelity trade,
    /// not the codec name.
    public var detail: String {
        switch self {
        case .high:   return "Original file, as the source served it."
        case .normal: return "AAC 96 kbps — about half the size."
        case .low:    return "HE-AAC 64 kbps — smallest downloads."
        }
    }

    /// Target bit rate, or nil when the file is kept as it arrived.
    ///
    /// Roughly: High is whatever the source served (~4–5 MB a song), Normal
    /// about half that, Low about a third.
    var bitRate: Int? {
        switch self {
        case .high:   return nil
        case .normal: return 96_000
        case .low:    return 64_000
        }
    }

    /// AAC-LC at 96 kbps, HE-AAC at 64.
    ///
    /// Plain AAC-LC starts to audibly fall apart below about 80 kbps stereo,
    /// which is exactly the gap SBR was designed to cover — so `.low` switches
    /// profile rather than just turning the same encoder down.
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

    /// Re-encodes `source` into `destination`, which is always an `.m4a`.
    ///
    /// Throws rather than falling back — the caller decides what a failed
    /// re-encode means, and for a download it means "file the original instead",
    /// not "the download failed".
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

        // Follow the source's shape instead of forcing 44.1 kHz stereo: upmixing
        // a mono upload to two channels spends twice the bits on one channel of
        // information.
        var channels   = 2
        var sampleRate = 44_100.0
        if let description = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if asbd.mChannelsPerFrame > 0 { channels   = Int(asbd.mChannelsPerFrame) }
            if asbd.mSampleRate      > 0 { sampleRate = asbd.mSampleRate }
        }
        // Beyond stereo there's no channel layout worth guessing at, and a
        // surround upload would otherwise fail configuration outright.
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

    /// Feeds decoded samples from the reader into the encoder until the source
    /// runs out, then finalises the file.
    private static func pump(reader: AVAssetReader,
                             writer: AVAssetWriter,
                             input:  AVAssetWriterInput,
                             output: AVAssetReaderTrackOutput) async throws {

        let queue = DispatchQueue(label: "mix.transcode")
        // `requestMediaDataWhenReady` calls back repeatedly and stops once the
        // input is marked finished, so in practice the flag flips once — but
        // resuming a continuation twice is a crash rather than a warning, and
        // the callback and the `finishWriting` handler run on different threads.
        let resumed = OneShot()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !resumed.isSet else { return }

                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()

                        // No more samples means either the source ended or the
                        // read gave out part-way. A truncated song that still
                        // looks like a finished download is the worse outcome,
                        // so a failed read is an error rather than a short file.
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

    /// One-shot latch guarding the continuation. A small class rather than a
    /// captured `var` so every closure sees the same value.
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
