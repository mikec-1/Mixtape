// SpotifyAuth.swift
// Mixtape
//
// Spotify login via Authorization Code + PKCE. Client-Credentials stopped
// returning playlist tracks in late 2024, so this now requires a signed-in user.

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

    /// What Mixtape asks Spotify for.
    ///
    /// The first two read playlists. `user-library-read` covers Liked Songs and
    /// saved albums, which are separate from playlists in Spotify's model and
    /// were unreachable until the library picker needed them.
    ///
    /// Read only, on purpose: this is the list `needsReauthorization` is judged
    /// against, and everything Mixtape does by default is a read. See
    /// `writeScopeList` for the other half and why it isn't in here.
    private static let scopeList = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
    ]
    private static let scopes = scopeList.joined(separator: " ")

    /// What sending things *to* Spotify needs — asked for separately.
    ///
    /// Kept out of `scopeList` so that adding export didn't hand every existing
    /// connection a "reconnect to continue" banner for a feature they may never
    /// use. Someone who only ever imports should never be asked for permission
    /// to write to their account; someone who exports is asked once, at the
    /// moment they ask to export, which is also the only moment the request
    /// makes any sense to them.
    private static let writeScopeList = [
        "playlist-modify-private",
        "playlist-modify-public",
        "user-library-modify",
    ]

    /// Asked for alongside the write scopes, but deliberately *not* part of
    /// `coversWriteScopes`.
    ///
    /// Uploading a playlist cover needs its own scope. Making it a requirement
    /// would tell everyone who granted write access before covers existed that
    /// their connection is broken, which it isn't — every other write still
    /// works. So it's requested at the next consent and the cover push treats a
    /// refusal as "this one thing can't be sent", not as a failure.
    private static let optionalWriteScopeList = ["ugc-image-upload"]

    @Published public private(set) var isAuthorized: Bool

    /// True when we hold a working token that was granted before this build
    /// started asking for library access.
    ///
    /// Scopes are fixed at consent: a refresh token issued against the old pair
    /// keeps refreshing happily and keeps reading playlists, it just answers 403
    /// to anything about Liked Songs. Nothing about the token looks broken, so
    /// without this the picker would show an empty Liked Songs and no reason
    /// why. The fix is another trip through the consent sheet, which we can only
    /// suggest if we know it's needed.
    @Published public private(set) var needsReauthorization: Bool

    /// Who the connection belongs to, once it's been asked. Cached here rather
    /// than in the view so switching Settings panes doesn't re-fetch it, and so
    /// signing out can drop it in the same breath as the token.
    @Published public private(set) var profile: SpotifyProfile?

    private var session: ASWebAuthenticationSession?
    private var profileLoad: Task<Void, Never>?
    /// Which account has already claimed (or been refused) the stored grant.
    /// Supabase re-publishes `.authenticated` on every token refresh, and
    /// without this each one cost a round-trip and a re-fetched profile.
    private var claimedAccount: UUID?

    /// Starts disconnected, on purpose.
    ///
    /// Which account this device holds a Spotify grant for isn't knowable until
    /// Supabase has restored a session, and assuming it was this one is the bug
    /// that let a connection outlive its account: the keychain item alone put
    /// the previous user's Spotify — profile, playlists and all — in front of
    /// whoever signed in next. `accountDidChange` turns it on once there is a
    /// user to check it against.
    public override init() {
        self.isAuthorized = false
        self.needsReauthorization = false
        self.canWrite = false
        super.init()
    }

    /// The stored grant, but only when it belongs to the account signed in now.
    ///
    /// The one place that decides whose connection this is. A grant with another
    /// owner is invisible from here down: not read, not refreshed, not pushed to
    /// the account — which is what keeps one person's Spotify off another
    /// person's devices even if the keychain item is still on this disk.
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
        if tokens == nil { profile = nil }
    }

    /// Whether a granted scope string includes everything this build needs.
    ///
    /// Tokens stored before Mixtape recorded scopes decode as nil, and those are
    /// exactly the ones granted under the old pair — treat unknown as stale.
    private static func coversCurrentScopes(_ granted: String?) -> Bool {
        guard let granted else { return false }
        let held = Set(granted.split(separator: " ").map(String.init))
        return held.isSuperset(of: scopeList)
    }

    /// Whether this connection may write to Spotify — create playlists, add
    /// songs, save likes.
    ///
    /// Read from the stored grant rather than remembered as a flag: scopes are
    /// fixed at consent and a refresh can never widen them, so the grant string
    /// is the only thing that actually knows.
    @Published public private(set) var canWrite: Bool = false

    private static func coversWriteScopes(_ granted: String?) -> Bool {
        guard let granted else { return false }
        let held = Set(granted.split(separator: " ").map(String.init))
        return held.isSuperset(of: writeScopeList)
    }

    // MARK: - Public API

    /// Show the consent sheet and exchange the code for tokens.
    ///
    /// `includingWrite` re-runs consent asking for the export scopes as well.
    /// It is a separate trip because Spotify fixes scopes at consent: there is
    /// no way to add a permission to a grant, only to replace the grant. The
    /// existing connection keeps working until the new one lands.
    public func connect(includingWrite: Bool = false) async throws {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: includingWrite
                  ? (Self.scopeList + Self.writeScopeList + Self.optionalWriteScopeList)
                        .joined(separator: " ")
                  : Self.scopes),
        ]
        guard let authURL = comps.url else { throw SpotifyAuthError.network }

        let callbackURL = try await authenticate(authURL: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            // No code means ?error=access_denied (user declined).
            throw SpotifyAuthError.cancelled
        }

        var tokens = try await exchangeCode(code, verifier: verifier)
        // Bind the grant to the account that asked for it. Consent happened
        // inside this session; anyone else signing in on this Mac gets nothing.
        tokens.owner = SupabaseConfig.client.auth.currentUser?.id
        Keychain.save(tokens)
        // Read it back rather than trusting the write. A keychain item that
        // didn't land leaves the app believing it holds a grant it doesn't, and
        // the first symptom is Spotify refusing a write for reasons nothing on
        // screen can explain.
        guard let stored = Keychain.load() else { throw SpotifyAuthError.network }
        AccountConnection.push(stored)
        publish(stored)
        // A fresh grant can be a different account than the last one.
        profile = nil

        // Consent is not the same as consent *granted*: Spotify will hand back a
        // token carrying fewer scopes than were asked for. Anything that needed
        // write access has to hear about that here, while the user is still in
        // front of the thing they just agreed to.
        if includingWrite, !canWrite { throw SpotifyAuthError.writeDeclined }
    }

    /// What Spotify actually granted this connection, as it wrote it.
    ///
    /// Read straight from the stored grant rather than from `canWrite`, because
    /// the whole question when a write is refused is whether those two agree.
    public var grantedScopes: String? { Self.currentTokens()?.scope }

    /// A token refreshed regardless of the stored expiry.
    ///
    /// For the one case `validAccessToken` can't cover: Spotify answered 401 to
    /// a token we believed was live. Clocks drift, tokens get revoked from the
    /// account page, and a long import can outlive its own token between the
    /// planning and the writing.
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

    /// Signing out hides the connection without ending it.
    ///
    /// The grant stays in the keychain, stamped with its owner, for the same
    /// reason the local library does: signing out isn't a request to disconnect
    /// Spotify, and the same person signing back in shouldn't have to consent
    /// again. It is unreachable while nobody is signed in — `currentTokens`
    /// won't hand it back without a matching user — and a *different* account
    /// signing in deletes it outright.
    public func signedOut() {
        claimedAccount = nil
        profileLoad?.cancel()
        profileLoad = nil
        publish(nil)
    }

    /// Claims, or discards, the stored grant for the account signing in.
    ///
    /// Called before the device's record of the last account is overwritten, so
    /// `previous` still names whoever was signed in until now.
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
                // Another account's grant, leaving with them. Local only: the
                // server row that `disconnect` deletes belongs to whoever is
                // signed in *now*, which is the wrong person entirely.
                Keychain.clear()
                publish(nil)
            }
        } else {
            publish(nil)
        }

        Task { await adoptAccountConnection() }
    }

    /// Fetches the account behind the token, once.
    ///
    /// Silent on failure by design: this only feeds a name and an avatar, and a
    /// connection that works shouldn't start reporting errors because one
    /// cosmetic request didn't land.
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

    /// Refreshes, stores and publishes the grant.
    ///
    /// Another device may have rotated the refresh token since this one last
    /// used it; when ours is refused, the account's copy gets one try.
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
        // A refresh can't widen a grant, so a missing scope here means "still
        // whatever it was" rather than "nothing".
        if let scope = refreshed.scope, !scope.isEmpty { stored.scope = scope }
        Keychain.save(stored)
        AccountConnection.push(stored)
        needsReauthorization = !Self.coversCurrentScopes(stored.scope)
        canWrite = Self.coversWriteScopes(stored.scope)
        return stored.accessToken
    }

    /// Picks up a connection made on another device (or the web).
    ///
    /// Called at launch. A device that already holds a grant publishes it
    /// instead, so connections made before the account copy existed reach the
    /// other devices without a reconnect. The Supabase session restores
    /// asynchronously, so this waits for a signed-in user first.
    public func adoptAccountConnection() async {
        // ponytail: polls up to ~20s for the session; hook the auth-state stream if launches get slower.
        for _ in 0..<20 where SupabaseConfig.client.auth.currentUser == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let userID = SupabaseConfig.client.auth.currentUser?.id else { return }
        // Only ever publishes a grant this account owns. The check used to be
        // absent, and the result was the leak in reverse: the outgoing user's
        // refresh token written straight into the incoming user's row.
        if let local = Self.currentTokens() {
            if await AccountConnection.fetch() == nil { AccountConnection.push(local) }
            return
        }
        guard let remote = await AccountConnection.fetch() else { return }
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
        /// Space-separated list of what Spotify actually granted, which is not
        /// always what was asked for.
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
    /// Scopes this grant carries. Optional so blobs written before Mixtape
    /// tracked scopes still decode — they come back nil, which is read as
    /// "granted under the old, narrower set", which is exactly what they were.
    var scope: String?
    /// Which Mixtape account this grant belongs to.
    ///
    /// A Spotify connection is a property of the account, not of the Mac it was
    /// made on. Without this the keychain item was a single device-global blob:
    /// signing out and into a second account left the first one's Spotify on
    /// screen, and `adoptAccountConnection` went on to publish that grant into
    /// the *new* account's `spotify_connections` row — handing one person's
    /// Spotify to another person's devices.
    ///
    /// Optional so grants written before this decode; a nil owner is resolved
    /// once, at the next sign-in, by `accountDidChange`.
    var owner: UUID?
}

// MARK: - Account copy

/// The grant's refresh token in `spotify_connections`, one row per user.
private enum AccountConnection {
    private struct Row: Codable {
        let user_id: UUID
        let refresh_token: String
        let scope: String?
    }

    static func fetch() async -> (refreshToken: String, scope: String?)? {
        let client = SupabaseConfig.client
        guard let userID = client.auth.currentUser?.id,
              let rows: [Row] = try? await client.from("spotify_connections")
                .select().eq("user_id", value: userID).limit(1).execute().value,
              let row = rows.first
        else { return nil }
        return (row.refresh_token, row.scope)
    }

    static func push(_ tokens: StoredTokens) {
        let client = SupabaseConfig.client
        // `tokens.owner == userID` is the load-bearing half: without it, a grant
        // left behind by the last account was published into whichever account
        // happened to be signed in when the app next looked.
        guard let userID = client.auth.currentUser?.id, !tokens.refreshToken.isEmpty,
              tokens.owner == userID else { return }
        let row = Row(user_id: userID, refresh_token: tokens.refreshToken, scope: tokens.scope)
        Task { _ = try? await client.from("spotify_connections").upsert(row).execute() }
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

    public var errorDescription: String? {
        switch self {
        case .cancelled:     return "Spotify login was cancelled."
        case .notAuthorized: return "Connect your Spotify account to import playlists."
        case .network:       return "Couldn't reach Spotify. Check your connection and try again."
        case .writeDeclined:
            return "Spotify didn't grant permission to change your account, so nothing was sent."
        }
    }
}

// MARK: - Keychain

/// Stores the token blob as a single generic-password item.
private enum Keychain {
    private static let service = "tech.mixtaped.spotify.oauth"
    private static let account = "tokens"

    static func save(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return nil
        }
        return tokens
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
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
