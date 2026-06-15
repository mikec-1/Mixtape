// StubFileStorageService.swift
// Mixtape — Core Services
//
// No-op FileStorageProtocol implementation for tests and previews.

import Foundation
import Combine

public final class StubFileStorageService: FileStorageProtocol {

    private let uploadSubject  = PassthroughSubject<TransferProgress, Never>()
    private let downloadSubject = PassthroughSubject<TransferProgress, Never>()

    public var uploadProgressPublisher:   AnyPublisher<TransferProgress, Never> { uploadSubject.eraseToAnyPublisher() }
    public var downloadProgressPublisher: AnyPublisher<TransferProgress, Never> { downloadSubject.eraseToAnyPublisher() }

    public init() {}

    public func upload(track: Track, accessToken: String) async throws -> String {
        print("[StubFileStorageService] upload() — stub, returning local path as key")
        return track.file.localPath
    }

    public func download(track: Track, accessToken: String) async throws -> URL {
        print("[StubFileStorageService] download() — stub, returning existing local URL")
        return track.file.localURL
    }

    public func delete(remoteKey: String, accessToken: String) async throws {
        print("[StubFileStorageService] delete(\(remoteKey)) — stub, no-op")
    }

    public func localURL(for track: Track) -> URL? {
        let url = track.file.localURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func clearLocalCache() throws {
        print("[StubFileStorageService] clearLocalCache() — stub, no-op")
    }

    public func localCacheSize() throws -> Int64 {
        return 0
    }
}
