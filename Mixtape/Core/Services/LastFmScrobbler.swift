// LastFmScrobbler.swift
// Mixtape — Core/Services
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ Last.fm scrobbler — full desktop web-auth flow implemented.               │
// │                                                                           │
// │ Builds correctly-signed Audioscrobbler 2.0 requests AND the desktop       │
// │ auth.getToken → user-authorize → auth.getSession flow.                    │
// │                                                                           │
// │ Setup the USER must do (inherent to Last.fm — no API key ships in-app):   │
// │   1. Register an app at https://www.last.fm/api/account/create to get an  │
// │      API key + shared secret, and paste them into Settings ▸ Last.fm.     │
// │   2. Tap "Connect" — the app opens the Last.fm authorize page, the user   │
// │      approves, then taps "Finish connecting" to fetch + persist the       │
// │      session key. (`beginWebAuth()` / `completeWebAuth()` below.)         │
// │                                                                           │
// │ Once connected, PlaybackEngine drives updateNowPlaying(track:) on play    │
// │ and scrobble(track:startedAt:) when playback crosses Last.fm's threshold  │
// │ (>50% of the track or 4 minutes, whichever first; tracks >30s only).      │
// └─────────────────────────────────────────────────────────────────────────┘

import Foundation
import Combine
import CryptoKit

@MainActor
public final class LastFmScrobbler: ObservableObject {

    public static let shared = LastFmScrobbler()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let apiKey     = "lastfm.apiKey"
        static let apiSecret  = "lastfm.apiSecret"
        static let sessionKey = "lastfm.sessionKey"
        static let username    = "lastfm.username"
        static let isEnabled  = "lastfm.isEnabled"
    }

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    /// User-authorize page for the desktop auth flow.
    private let authPage = "https://www.last.fm/api/auth/"

    // MARK: - State

    /// User-facing on/off switch, persisted to UserDefaults. When false the
    /// service no-ops even if credentials are present.
    @Published public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled) }
    }

    /// The connected Last.fm username, or nil when not connected. Published so the
    /// settings UI can reflect connection state live. Persisted.
    @Published public private(set) var username: String?

    /// True while a getToken/getSession round-trip is in flight.
    @Published public private(set) var isConnecting: Bool = false

    /// The most recent auth error, surfaced in the UI. Cleared on a new attempt.
    @Published public private(set) var lastAuthError: String?

    /// The unauthorized request token captured by `beginWebAuth()`, consumed by
    /// `completeWebAuth()`. In-memory only — the app stays running across the
    /// browser round-trip, so it never needs to be persisted.
    private var pendingToken: String?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        self.username  = nonEmpty(UserDefaults.standard.string(forKey: Keys.username))
    }

    // MARK: - Credentials (read from UserDefaults)

    private var apiKey:     String? { nonEmpty(UserDefaults.standard.string(forKey: Keys.apiKey)) }
    private var apiSecret:  String? { nonEmpty(UserDefaults.standard.string(forKey: Keys.apiSecret)) }
    private var sessionKey: String? { nonEmpty(UserDefaults.standard.string(forKey: Keys.sessionKey)) }

    /// True once an API key + shared secret have been saved (auth can begin).
    public var hasCredentials: Bool {
        apiKey != nil && apiSecret != nil
    }

    /// True only when an API key, shared secret, and an authenticated session key
    /// are all present. Until then scrobbling silently no-ops.
    public var isConfigured: Bool {
        apiKey != nil && apiSecret != nil && sessionKey != nil
    }

    // MARK: - Connection management

    /// Persist the user's API key + shared secret. Does not authenticate — call
    /// `beginWebAuth()`/`completeWebAuth()` afterwards to obtain a session key.
    public func saveCredentials(apiKey: String, apiSecret: String) {
        let defaults = UserDefaults.standard
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
        defaults.set(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiSecret)
        objectWillChange.send()
    }

    /// Disconnect: wipe the session key + username (keeps the saved API key/secret
    /// so the user can reconnect without re-entering them).
    public func disconnect() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.sessionKey)
        defaults.removeObject(forKey: Keys.username)
        username = nil
        pendingToken = nil
        lastAuthError = nil
        objectWillChange.send()
    }

    /// Forget everything: API key, secret, session, username, and disable scrobbling.
    public func forgetCredentials() {
        let defaults = UserDefaults.standard
        [Keys.apiKey, Keys.apiSecret, Keys.sessionKey, Keys.username].forEach(defaults.removeObject)
        username = nil
        pendingToken = nil
        lastAuthError = nil
        isEnabled = false
        objectWillChange.send()
    }

    // MARK: - Web auth flow (auth.getToken → authorize → auth.getSession)

    /// Step 1: fetch an unauthorized request token and return the Last.fm authorize
    /// URL the caller should open in a browser. Requires saved credentials.
    public func beginWebAuth() async throws -> URL {
        guard let apiKey, apiSecret != nil else { throw AuthError.missingCredentials }
        lastAuthError = nil
        isConnecting = true
        defer { isConnecting = false }

        do {
            let json = try await signedGET(["method": "auth.getToken"])
            guard let token = json["token"] as? String, !token.isEmpty else {
                throw AuthError.unexpectedResponse
            }
            pendingToken = token

            var components = URLComponents(string: authPage)!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "token",   value: token),
            ]
            guard let url = components.url else { throw AuthError.unexpectedResponse }
            return url
        } catch let error as AuthError {
            lastAuthError = error.errorDescription
            throw error
        } catch {
            lastAuthError = error.localizedDescription
            throw error
        }
    }

    /// Step 2: after the user authorizes in the browser, exchange the pending token
    /// for a session key and persist it + the username. Marks scrobbling enabled.
    public func completeWebAuth() async throws {
        guard let token = pendingToken else { throw AuthError.noPendingToken }
        lastAuthError = nil
        isConnecting = true
        defer { isConnecting = false }

        do {
            let json = try await signedGET(["method": "auth.getSession", "token": token])
            guard
                let session = json["session"] as? [String: Any],
                let key = session["key"] as? String, !key.isEmpty
            else {
                throw AuthError.unexpectedResponse
            }
            let name = session["name"] as? String

            let defaults = UserDefaults.standard
            defaults.set(key, forKey: Keys.sessionKey)
            if let name { defaults.set(name, forKey: Keys.username) }

            username = name
            pendingToken = nil
            isEnabled = true
            objectWillChange.send()
        } catch let error as AuthError {
            lastAuthError = error.errorDescription
            throw error
        } catch {
            lastAuthError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Auth errors

    public enum AuthError: LocalizedError {
        case missingCredentials
        case noPendingToken
        case unexpectedResponse

        public var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Enter your Last.fm API key and shared secret first."
            case .noPendingToken:     return "Tap Connect and authorise in your browser before finishing."
            case .unexpectedResponse: return "Last.fm returned an unexpected response. Check your API key and secret."
            }
        }
    }

    // MARK: - Public API
    //
    // Both methods no-op gracefully (return early) when the service is disabled
    // or unconfigured, so callers can invoke them unconditionally.

    /// Submits a completed listen to Last.fm (`track.scrobble`).
    /// - Parameter startedAt: when the user *began* playing the track. Last.fm
    ///   expects the start timestamp, not the completion time.
    public func scrobble(track: Track, startedAt: Date) async {
        guard isEnabled, isConfigured else { return }   // inert until configured

        var params: [String: String] = [
            "method":    "track.scrobble",
            "artist":    track.artistName,
            "track":     track.title,
            "timestamp": String(Int(startedAt.timeIntervalSince1970))
        ]
        if !track.albumTitle.isEmpty { params["album"] = track.albumTitle }
        if track.duration > 0        { params["duration"] = String(Int(track.duration.rounded())) }

        await send(params)
    }

    /// Updates the user's "now playing" status (`track.updateNowPlaying`).
    /// This is a transient status update and is never persisted as a scrobble.
    public func updateNowPlaying(track: Track) async {
        guard isEnabled, isConfigured else { return }   // inert until configured

        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "artist": track.artistName,
            "track":  track.title
        ]
        if !track.albumTitle.isEmpty { params["album"] = track.albumTitle }
        if track.duration > 0        { params["duration"] = String(Int(track.duration.rounded())) }

        await send(params)
    }

    // MARK: - Request construction (real, ready once keys exist)

    /// Adds the api_key + session key, signs the request, and POSTs it form-encoded.
    /// Response parsing is intentionally minimal; failed scrobbles are not retried or queued.
    private func send(_ baseParams: [String: String]) async {
        guard let apiKey, let apiSecret, let sessionKey else { return }

        var params = baseParams
        params["api_key"] = apiKey
        params["sk"]      = sessionKey

        // The api_sig is an md5 of every (key + value) pair sorted by key name,
        // concatenated, with the shared secret appended. `format` and `callback`
        // are excluded from the signature per the Last.fm spec.
        params["api_sig"] = signature(params, secret: apiSecret)

        // We request JSON for easier parsing; `format` is added AFTER signing.
        params["format"] = "json"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(params).data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // Failures are logged rather than surfaced or queued.
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[LastFmScrobbler] Request failed (\(http.statusCode)): \(body)")
            }
        } catch {
            print("[LastFmScrobbler] Network error: \(error)")
        }
    }

    /// Signs `baseParams` (adding api_key), performs a GET, and returns parsed JSON.
    /// Used by the auth flow (auth.getToken / auth.getSession). Throws on transport
    /// errors or a Last.fm `error` payload.
    private func signedGET(_ baseParams: [String: String]) async throws -> [String: Any] {
        guard let apiKey, let apiSecret else { throw AuthError.missingCredentials }

        var params = baseParams
        params["api_key"] = apiKey
        params["api_sig"] = signature(params, secret: apiSecret)
        params["format"]  = "json"   // added AFTER signing, per the Last.fm spec

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw AuthError.unexpectedResponse }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.unexpectedResponse
        }
        // Last.fm signals failures with an `error` (code) + `message`.
        if let message = json["message"] as? String, json["error"] != nil {
            lastAuthError = message
            throw AuthError.unexpectedResponse
        }
        return json
    }

    /// Computes the Last.fm `api_sig`: md5( join(sorted "keyvalue" pairs) + secret ).
    /// `format` and `callback` are never part of the signature.
    private func signature(_ params: [String: String], secret: String) -> String {
        let signable = params
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined()
        return md5Hex(signable + secret)
    }

    private func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    private func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
