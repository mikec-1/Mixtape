// Spotify login via Authorization Code + PKCE. Client-Credentials stopped
// returning playlist tracks in late 2024.

import Foundation
import AuthenticationServices
import Combine
import CryptoKit
import Supabase

@MainActor
public final class SpotifyAuth: NSObject, ObservableObject {

    // PKCE only needs the public client ID, no secret.
    private static let clientID    = "0e312a528cc34744b92021bed3f6edc9"
    private static let redirectURI = "mixtape://spotify-callback"
    private static let callbackScheme = "mixtape"

    /// Read scopes: playlists, plus user-library-read for Liked Songs and saved
    /// albums. needsReauthorization is judged against this list; write scopes are
    /// separate (see writeScopeList).
    private static let scopeList = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
    ]

    /// Scopes for exporting to Spotify, asked for separately so existing
    /// connections aren't told to reconnect for a feature they may never use.
    private static let writeScopeList = [
        "playlist-modify-private",
        "playlist-modify-public",
        "user-library-modify",
    ]

    /// Cover upload scope. Requested with the write scopes but not required by
    /// coversWriteScopes, so older write grants still count as working. A refusal
    /// just means covers aren't sent.
    private static let optionalWriteScopeList = ["ugc-image-upload"]

    /// Let the spotify_history job read recent plays and the four-week top list for
    /// the monthly recap. Asked for only when someone turns that on.
    private static let historyScopes = ["user-read-recently-played", "user-top-read"]

    /// Whether this account adds its Spotify plays to recaps. Lives on the
    /// spotify_connections row so every device and the server job see the same answer.
    @Published public private(set) var historySync = false

    @Published public private(set) var isAuthorized: Bool

    /// True when the stored token predates the library scopes. It still refreshes
    /// and reads playlists but 403s on Liked Songs, so we prompt for re-consent.
    @Published public private(set) var needsReauthorization: Bool

    /// The connected account, cached so Settings doesn't refetch it and sign-out
    /// can drop it with the token.
    @Published public private(set) var profile: SpotifyProfile?

    private var session: ASWebAuthenticationSession?
    private var profileLoad: Task<Void, Never>?
    /// The account that already claimed or was refused the grant. Supabase
    /// republishes .authenticated on every refresh.
    private var claimedAccount: UUID?

    /// Starts disconnected. The grant's owner isn't known until Supabase restores
    /// a session; accountDidChange enables it once there's a user to check.
    public override init() {
        self.isAuthorized = false
        self.needsReauthorization = false
        self.canWrite = false
        super.init()
    }

    /// The stored grant, only if it belongs to the signed-in account. Anything
    /// else is never read, refreshed or pushed.
    private static func currentTokens() -> StoredTokens? {
        guard let stored = Keychain.load(),
              let userID = SupabaseConfig.client.auth.currentUser?.id,
              stored.owner == userID
        else { return nil }
        return stored
    }

    /// Mirrors a grant (or its absence) into the published state.
    private func publish(_ tokens: StoredTokens?) {
        isAuthorized = tokens != nil
        needsReauthorization = tokens.map { !Self.coversCurrentScopes($0.scope) } ?? false
        canWrite = Self.coversWriteScopes(tokens?.scope)
        if tokens == nil { profile = nil; historySync = false }
    }

    /// Whether granted scopes cover this build's list. Nil (older tokens) is stale.
    private static func coversCurrentScopes(_ granted: String?) -> Bool {
        guard let granted else { return false }
        let held = Set(granted.split(separator: " ").map(String.init))
        return held.isSuperset(of: scopeList)
    }

    /// Whether this connection can write to Spotify. Read from the stored grant;
    /// a refresh can't widen scopes.
    @Published public private(set) var canWrite: Bool = false

    private static func coversWriteScopes(_ granted: String?) -> Bool {
        guard let granted else { return false }
        let held = Set(granted.split(separator: " ").map(String.init))
        return held.isSuperset(of: writeScopeList)
    }

    // MARK: - Public API

    /// Shows the consent sheet and exchanges the code for tokens.
    /// `includingWrite` asks for export scopes too. Spotify can't add scopes to a
    /// grant, only replace it, so scopes already held are asked for again.
    public func connect(includingWrite: Bool = false, includingHistory: Bool = false) async throws {
        var scopes = Self.scopeList
        if includingWrite || canWrite { scopes += Self.writeScopeList + Self.optionalWriteScopeList }
        if includingHistory || historySync || !heldScopes.isDisjoint(with: Self.historyScopes) {
            scopes += Self.historyScopes
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: scopes.joined(separator: " ")),
        ]
        guard let authURL = comps.url else { throw SpotifyAuthError.network }

        let callbackURL = try await authenticate(authURL: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            // No code means ?error=access_denied (user declined).
            throw SpotifyAuthError.cancelled
        }

        var tokens = try await exchangeCode(code, verifier: verifier)
        // Bind the grant to the account that asked for it.
        tokens.owner = SupabaseConfig.client.auth.currentUser?.id
        Keychain.save(tokens)
        // Read it back rather than trusting the write.
        guard let stored = Keychain.load() else { throw SpotifyAuthError.network }
        await AccountConnection.save(stored)
        publish(stored)
        // A fresh grant can be a different account than the last one.
        profile = nil

        // Spotify can grant fewer scopes than asked. Report it now, while the user
        // is still looking.
        if includingWrite, !canWrite { throw SpotifyAuthError.writeDeclined }
    }

    /// What Spotify actually granted, straight from the stored grant.
    public var grantedScopes: String? { Self.currentTokens()?.scope }

    private var heldScopes: Set<String> {
        Set((grantedScopes ?? "").split(separator: " ").map(String.init))
    }

    private var holdsHistoryScope: Bool { heldScopes.isSuperset(of: Self.historyScopes) }

    /// Turns recap syncing on or off for the account. Turning it on without the
    /// history scope asks Spotify for it first. Plays already copied are kept.
    public func setHistorySync(_ on: Bool) async throws {
        if on, !holdsHistoryScope {
            try await connect(includingHistory: true)
            guard holdsHistoryScope else { throw SpotifyAuthError.historyDeclined }
        }
        try await AccountConnection.setHistorySync(on)
        historySync = on
    }

    /// A token refreshed regardless of expiry, for when Spotify 401s a token we
    /// thought was live (clock drift, revocation, a long import).
    public func refreshedAccessToken() async throws -> String {
        guard let stored = Self.currentTokens() else { throw SpotifyAuthError.notAuthorized }
        return try await refreshAndStore(stored)
    }

    public func disconnect() {
        Keychain.clear()
        AccountConnection.delete()
        profileLoad?.cancel()
        profileLoad = nil
        publish(nil)
    }

    /// Hides the connection without ending it. The grant stays in the keychain
    /// with its owner, so the same user signing back in doesn't re-consent. A
    /// different account signing in deletes it.
    public func signedOut() {
        claimedAccount = nil
        profileLoad?.cancel()
        profileLoad = nil
        publish(nil)
    }

    /// Claims or discards the stored grant for the account signing in. Called
    /// before the last-account record changes, so `previous` is still the old user.
    public func accountDidChange(to userID: UUID, previous: String?) {
        guard claimedAccount != userID else { return }
        claimedAccount = userID
        profileLoad?.cancel()
        profileLoad = nil
        profile = nil

        if let held = Keychain.load() {
            if CredentialOwner.belongs(owner: held.owner?.uuidString,
                                       to: userID, previous: previous) {
                var claimed = held
                if claimed.owner == nil {
                    claimed.owner = userID
                    Keychain.save(claimed)
                }
                publish(claimed)
            } else {
                // Another account's grant. Local only: the server row belongs to whoever's
                // signed in now.
                Keychain.clear()
                publish(nil)
            }
        } else {
            publish(nil)
        }

        Task { await adoptAccountConnection() }
    }

    /// Fetches the account behind the token once. Silent on failure; it's cosmetic.
    public func loadProfile(using client: SpotifyClient, force: Bool = false) {
        guard isAuthorized else { return }
        if profile != nil, !force { return }
        guard profileLoad == nil || force else { return }
        profileLoad?.cancel()
        profileLoad = Task { [weak self] in
            guard let self else { return }
            defer { self.profileLoad = nil }
            guard let token = try? await self.validAccessToken(),
                  let loaded = try? await client.fetchProfile(accessToken: token)
            else { return }
            guard !Task.isCancelled else { return }
            self.profile = loaded
        }
    }

    /// Access token, refreshed if the stored one has expired.
    public func validAccessToken() async throws -> String {
        guard let stored = Self.currentTokens() else { throw SpotifyAuthError.notAuthorized }
        if Date() < stored.expiry { return stored.accessToken }
        return try await refreshAndStore(stored)
    }

    /// Refreshes, stores and publishes the grant. If our refresh token was
    /// rotated by another device, the account's copy gets one try.
    private func refreshAndStore(_ current: StoredTokens) async throws -> String {
        var stored = current
        let refreshed: StoredTokens
        do {
            refreshed = try await refresh(using: stored.refreshToken)
        } catch {
            guard let remote = await AccountConnection.fetch(),
                  remote.refreshToken != stored.refreshToken else { throw error }
            refreshed = try await refresh(using: remote.refreshToken)
            if refreshed.scope == nil { stored.scope = remote.scope }
        }
        stored.accessToken = refreshed.accessToken
        stored.expiry = refreshed.expiry
        // Spotify doesn't always send a new refresh token; keep the old one if so.
        if !refreshed.refreshToken.isEmpty { stored.refreshToken = refreshed.refreshToken }
        // A refresh can't widen a grant, so no scope means unchanged.
        if let scope = refreshed.scope, !scope.isEmpty { stored.scope = scope }
        Keychain.save(stored)
        AccountConnection.push(stored)
        needsReauthorization = !Self.coversCurrentScopes(stored.scope)
        canWrite = Self.coversWriteScopes(stored.scope)
        return stored.accessToken
    }

    /// Adopts a connection made on another device or the web. A device with its
    /// own grant publishes it instead. Waits for Supabase to restore a user first.
    public func adoptAccountConnection() async {
        // ponytail: polls up to ~20s for the session; hook the auth-state stream if launches get slower.
        for _ in 0..<20 where SupabaseConfig.client.auth.currentUser == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let userID = SupabaseConfig.client.auth.currentUser?.id else { return }
        // Only publish a grant this account owns.
        if let local = Self.currentTokens() {
            let remote = await AccountConnection.fetch()
            if remote == nil { AccountConnection.push(local) }
            historySync = remote?.historySync ?? false
            return
        }
        guard let remote = await AccountConnection.fetch() else { return }
        historySync = remote.historySync
        let seed = StoredTokens(accessToken: "", refreshToken: remote.refreshToken,
                                expiry: .distantPast, scope: remote.scope, owner: userID)
        guard (try? await refreshAndStore(seed)) != nil else { return }
        isAuthorized = true
        profile = nil
    }

    // MARK: - ASWebAuthenticationSession

    private func authenticate(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.network)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SpotifyAuthError.network)
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(_ code: String, verifier: String) async throws -> StoredTokens {
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier,
        ]
        return try await tokenRequest(body)
    }

    private func refresh(using refreshToken: String) async throws -> StoredTokens {
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        return try await tokenRequest(body)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> StoredTokens {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyAuthError.network
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyAuthError.network
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return StoredTokens(
            accessToken:  decoded.access_token,
            refreshToken: decoded.refresh_token ?? fields["refresh_token"] ?? "",
            // expire 60s early so we never hand back a token mid-request
            expiry: Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60)),
            scope: decoded.scope
        )
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        /// Space-separated scopes Spotify granted, which may be fewer than asked.
        let scope: String?
    }
}

// MARK: - Presentation anchor

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.windows.first { $0.isKeyWindow }
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow
            ?? scene?.windows.first
            ?? ASPresentationAnchor()
        #endif
    }
}

// MARK: - Stored tokens

struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// Scopes this grant carries. Nil for old blobs, read as the old narrower set.
    var scope: String?
    /// The Mixtape account this grant belongs to, so one person's Spotify never
    /// shows up for another account. Nil for old grants; resolved at the next
    /// sign-in by accountDidChange.
    var owner: UUID?
}

// MARK: - Account copy

/// The grant's refresh token in `spotify_connections`, one row per user.
private enum AccountConnection {
    private struct Row: Codable {
        let user_id: UUID
        let refresh_token: String
        let scope: String?
        /// Left nil on token writes so they never touch the setting.
        var history_sync: Bool? = nil
    }

    static func fetch() async -> (refreshToken: String, scope: String?, historySync: Bool)? {
        let client = SupabaseConfig.client
        guard let userID = client.auth.currentUser?.id,
              let rows: [Row] = try? await client.from("spotify_connections")
                .select().eq("user_id", value: userID).limit(1).execute().value,
              let row = rows.first
        else { return nil }
        return (row.refresh_token, row.scope, row.history_sync ?? false)
    }

    static func push(_ tokens: StoredTokens) {
        Task { await save(tokens) }
    }

    static func save(_ tokens: StoredTokens) async {
        let client = SupabaseConfig.client
        // The owner check keeps a previous account's grant out of this account's row.
        guard let userID = client.auth.currentUser?.id, !tokens.refreshToken.isEmpty,
              tokens.owner == userID else { return }
        let row = Row(user_id: userID, refresh_token: tokens.refreshToken, scope: tokens.scope)
        _ = try? await client.from("spotify_connections").upsert(row).execute()
    }

    /// An update, not an upsert: this device's refresh token may be older than the row's.
    static func setHistorySync(_ on: Bool) async throws {
        let client = SupabaseConfig.client
        guard let userID = client.auth.currentUser?.id else { throw SpotifyAuthError.notAuthorized }
        try await client.from("spotify_connections")
            .update(["history_sync": on]).eq("user_id", value: userID).execute()
    }

    static func delete() {
        let client = SupabaseConfig.client
        guard let userID = client.auth.currentUser?.id else { return }
        Task { _ = try? await client.from("spotify_connections").delete().eq("user_id", value: userID).execute() }
    }
}

// MARK: - Errors

public enum SpotifyAuthError: LocalizedError {
    case cancelled
    case notAuthorized
    case network
    /// Consent came back without the permissions the action needed.
    case writeDeclined
    case historyDeclined

    public var errorDescription: String? {
        switch self {
        case .cancelled:     return "Spotify login was cancelled."
        case .notAuthorized: return "Connect your Spotify account to import playlists."
        case .network:       return "Couldn't reach Spotify. Check your connection and try again."
        case .writeDeclined:
            return "Spotify didn't grant permission to change your account, so nothing was sent."
        case .historyDeclined:
            return "Spotify didn't grant access to your listening history."
        }
    }
}

// MARK: - Keychain

/// Stores the token blob. iOS keeps it as a single generic-password item. macOS
/// keeps it in a 0600 file beside the Supabase session (see FileAuthLocalStorage):
/// the login keychain's per-app ACL prompts whenever the build's signature
/// changes, which is every ad-hoc release, and that prompt blocked the main thread
/// at launch. The data protection keychain needs a provisioning profile, which
/// ad-hoc signing doesn't have.
private enum Keychain {
    private static let service = "tech.mixtaped.spotify.oauth"
    private static let account = "tokens"
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]

    static func save(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        #if os(macOS)
        // Drop the keychain copy only once the file holds the tokens.
        guard (try? file.store(key: fileKey, value: data)) != nil else { return }
        withoutPrompts { _ = SecItemDelete(query as CFDictionary) }
        #else
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }

    static func load() -> StoredTokens? {
        #if os(macOS)
        if let data = try? file.retrieve(key: fileKey) {
            return try? JSONDecoder().decode(StoredTokens.self, from: data)
        }
        // One-time move out of the keychain. Only a build signed like the one that
        // wrote the item can read it silently; any other grant comes back from the
        // account copy in adoptAccountConnection.
        guard let tokens = withoutPrompts({ keychainLoad() }) else { return nil }
        save(tokens)
        return tokens
        #else
        return keychainLoad()
        #endif
    }

    static func clear() {
        #if os(macOS)
        try? file.remove(key: fileKey)
        withoutPrompts { _ = SecItemDelete(query as CFDictionary) }
        #else
        SecItemDelete(query as CFDictionary)
        #endif
    }

    private static func keychainLoad() -> StoredTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    #if os(macOS)
    private static let file = FileAuthLocalStorage()
    private static let fileKey = "spotify-tokens"

    /// Runs keychain calls that fail rather than show the access prompt.
    /// kSecUseAuthenticationUIFail doesn't cover the login keychain's ACL prompt.
    private static func withoutPrompts<T>(_ body: () -> T) -> T {
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
    #endif
}

// MARK: - Base64URL

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
