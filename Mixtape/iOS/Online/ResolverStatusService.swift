// ResolverStatusService.swift
// Mixtape — iOS/Online
//
// Tracks which streaming resolver iOS is talking to and whether it's reachable,
// so Settings can show "Connected via Hosted / Your Mac". macOS resolves locally
// and is always connected, so this is iOS-only.
//
// Probes on demand (Settings opens, foreground, Test tapped) rather than on a
// timer to avoid background battery/data cost. Walks the resolver's own failover
// order so the reported source matches the one that'll actually serve a play.

#if os(iOS)
import Foundation
import Combine

@MainActor
public final class ResolverStatusService: ObservableObject {

    public enum Status: Equatable { case checking, online, offline }

    /// Reachability of the active source. Drives the status dot.
    @Published public private(set) var status: Status = .checking
    /// The source currently serving (or about to serve) streams, if any.
    @Published public private(set) var activeSource: ResolverSource?

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Re-probe the source list and publish the first reachable one. Returns the
    /// chosen source (nil if everything is unreachable).
    @discardableResult
    public func refresh() async -> ResolverSource? {
        status = .checking
        for source in RemoteResolverService.orderedSources() {
            if await Self.isHealthy(source.baseURL, session: session) {
                activeSource = source
                status = .online
                return source
            }
        }
        activeSource = nil
        status = .offline
        return nil
    }

    /// Record that `source` just successfully served a request (called by the
    /// resolver after a real play), keeping the status dot truthful without a
    /// separate probe.
    public func markActive(_ source: ResolverSource) {
        activeSource = source
        status = .online
    }

    /// GET /health on a base URL, true on a 2xx. /health needs no auth, but we
    /// send the token anyway so it works regardless of server config.
    static func isHealthy(_ base: URL, session: URLSession) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 6
        req = RemoteResolverService.authorized(req)
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
#endif
