// SpotifyAuth.swift
// Mixtape
//
// Spotify login via Authorization Code + PKCE. Client-Credentials stopped
// returning playlist tracks in late 2024, so this now requires a signed-in user.

import Foundation
import AuthenticationServices
import Combine
import CryptoKit

@MainActor
public final class SpotifyAuth: NSObject, ObservableObject {

    // PKCE only needs the public client ID, no secret.
    private static let clientID    = "0e312a528cc34744b92021bed3f6edc9"
    private static let redirectURI = "mixtape://spotify-callback"
    private static let callbackScheme = "mixtape"
    private static let scopes = "playlist-read-private playlist-read-collaborative"

    @Published public private(set) var isAuthorized: Bool

    private var session: ASWebAuthenticationSession?

    public override init() {
        self.isAuthorized = Keychain.load() != nil
        super.init()
    }

    // MARK: - Public API

    /// Show the consent sheet and exchange the code for tokens.
    public func connect() async throws {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
        ]
        guard let authURL = comps.url else { throw SpotifyAuthError.network }

        let callbackURL = try await authenticate(authURL: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            // No code means ?error=access_denied (user declined).
            throw SpotifyAuthError.cancelled
        }

        let tokens = try await exchangeCode(code, verifier: verifier)
        Keychain.save(tokens)
        isAuthorized = true
    }

    public func disconnect() {
        Keychain.clear()
        isAuthorized = false
    }

    /// Access token, refreshed if the stored one has expired.
    public func validAccessToken() async throws -> String {
        guard var stored = Keychain.load() else { throw SpotifyAuthError.notAuthorized }
        if Date() < stored.expiry { return stored.accessToken }

        let refreshed = try await refresh(using: stored.refreshToken)
        stored.accessToken = refreshed.accessToken
        stored.expiry = refreshed.expiry
        // Spotify doesn't always send a new refresh token; keep the old one if so.
        if !refreshed.refreshToken.isEmpty { stored.refreshToken = refreshed.refreshToken }
        Keychain.save(stored)
        return stored.accessToken
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
            expiry: Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
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
}

// MARK: - Errors

public enum SpotifyAuthError: LocalizedError {
    case cancelled
    case notAuthorized
    case network

    public var errorDescription: String? {
        switch self {
        case .cancelled:     return "Spotify login was cancelled."
        case .notAuthorized: return "Connect your Spotify account to import playlists."
        case .network:       return "Couldn't reach Spotify. Check your connection and try again."
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
