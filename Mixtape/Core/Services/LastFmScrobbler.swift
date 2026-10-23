// Last.fm scrobbler (Audioscrobbler 2.0). The user supplies their own API key
// and secret in Settings, then connects via the desktop web-auth flow.
// Scrobbles at 50% or 4 minutes, for tracks over 30s.

import Foundation
import Combine
import CryptoKit
import OSLog
import Observation

@Observable
@MainActor
public final class LastFmScrobbler {

    public static let shared = LastFmScrobbler()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let apiKey     = "lastfm.apiKey"
        static let apiSecret  = "lastfm.apiSecret"
        static let sessionKey = "lastfm.sessionKey"
        static let username    = "lastfm.username"
        static let isEnabled  = "lastfm.isEnabled"
        static let owner      = "lastfm.ownerUserID"
    }

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    /// User-authorize page for the desktop auth flow.
    private let authPage = "https://www.last.fm/api/auth/"

    // MARK: - State

    /// When off, nothing is sent even if connected.
    public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled) }
    }

    /// Nil when not connected.
    public private(set) var username: String?

    /// True while a getToken/getSession round-trip is in flight.
    public private(set) var isConnecting: Bool = false

    /// The most recent auth error, surfaced in the UI. Cleared on a new attempt.
    public private(set) var lastAuthError: String?

    /// Token from beginWebAuth(), used by completeWebAuth(). Memory only.
    @ObservationIgnored private var pendingToken: String?

    /// The Mixtape account the stored credentials belong to. They live in
    /// device-wide UserDefaults, so nothing is readable until accountDidChange claims them.
    @ObservationIgnored private var accountID: UUID?

    private init() {
        // Unclaimed until an account signs in.
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        self.username  = nil
    }

    // MARK: - Credentials (read from UserDefaults, once the account owns them)

    private var apiKey:     String? { claimed(Keys.apiKey) }
    private var apiSecret:  String? { claimed(Keys.apiSecret) }
    private var sessionKey: String? { claimed(Keys.sessionKey) }

    /// The credentials live in UserDefaults, so writers bump this for views to redraw.
    private var credentialsRevision = 0

    private func claimed(_ key: String) -> String? {
        _ = credentialsRevision
        guard accountID != nil else { return nil }
        return nonEmpty(UserDefaults.standard.string(forKey: key))
    }

    // MARK: - Account binding

    /// Claims or wipes the stored credentials for the signing-in account.
    /// `previous` is whoever was signed in before.
    public func accountDidChange(to userID: UUID, previous: String?) {
        // Token refreshes re-send sign-in.
        guard accountID != userID else { return }
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: Keys.owner)
        guard CredentialOwner.belongs(owner: owner, to: userID, previous: previous) else {
            // Different person, so wipe their credentials.
            accountID = nil
            forgetCredentials()
            return
        }
        defaults.set(userID.uuidString, forKey: Keys.owner)
        accountID = userID
        username = nonEmpty(defaults.string(forKey: Keys.username))
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        credentialsRevision += 1
    }

    /// Hides the connection without ending it, so signing back in keeps the key.
    public func signedOut() {
        accountID = nil
        username = nil
        pendingToken = nil
        lastAuthError = nil
        credentialsRevision += 1
    }

    /// True once an API key + shared secret have been saved (auth can begin).
    public var hasCredentials: Bool {
        apiKey != nil && apiSecret != nil
    }

    /// Needs a key, secret and session key.
    public var isConfigured: Bool {
        apiKey != nil && apiSecret != nil && sessionKey != nil
    }

    // MARK: - Connection management

    /// Saves the key and secret. Doesn't authenticate.
    public func saveCredentials(apiKey: String, apiSecret: String) {
        let defaults = UserDefaults.standard
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
        defaults.set(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiSecret)
        credentialsRevision += 1
    }

    /// Clears the session and username, keeps the key and secret.
    public func disconnect() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.sessionKey)
        defaults.removeObject(forKey: Keys.username)
        username = nil
        pendingToken = nil
        lastAuthError = nil
        credentialsRevision += 1
    }

    /// Forget everything: API key, secret, session, username, and disable scrobbling.
    public func forgetCredentials() {
        let defaults = UserDefaults.standard
        [Keys.apiKey, Keys.apiSecret, Keys.sessionKey, Keys.username, Keys.owner]
            .forEach(defaults.removeObject)
        username = nil
        pendingToken = nil
        lastAuthError = nil
        isEnabled = false
        credentialsRevision += 1
    }

    // MARK: - Web auth flow (auth.getToken -> authorize -> auth.getSession)

    /// Step 1: get a request token and return the authorize URL to open.
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

    /// Step 2: exchange the authorized token for a session key.
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
            credentialsRevision += 1
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
    // Both no-op when disabled or unconfigured.

    /// Submits a finished listen. startedAt is when playback began, as Last.fm expects.
    public func scrobble(track: Track, startedAt: Date) async {
        guard isEnabled, isConfigured, !PrivateSession.isActive else { return }

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

    /// Sets "now playing". Not a scrobble.
    public func updateNowPlaying(track: Track) async {
        guard isEnabled, isConfigured, !PrivateSession.isActive else { return }

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

    /// Signs and POSTs. Failures aren't retried.
    private func send(_ baseParams: [String: String]) async {
        guard let apiKey, let apiSecret, let sessionKey else { return }

        var params = baseParams
        params["api_key"] = apiKey
        params["sk"]      = sessionKey

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
                MixLog.playback.error("[LastFmScrobbler] Request failed (\(http.statusCode)): \(body)")
            }
        } catch {
            MixLog.playback.error("[LastFmScrobbler] Network error: \(error)")
        }
    }

    /// Signed GET for the auth calls. Throws on errors.
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

    /// md5 of the sorted key+value pairs plus the secret, without format and callback.
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
