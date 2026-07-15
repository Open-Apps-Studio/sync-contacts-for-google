import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// PKCE OAuth for a Google iOS client (no client secret, custom-scheme redirect).
/// The app presents `authorizationURL` in ASWebAuthenticationSession and feeds the
/// callback URL back into `exchangeCode`.
public struct GoogleOAuthConfig: Sendable {
    public var clientID: String
    /// Reverse-DNS custom scheme, e.g. "com.googleusercontent.apps.XYZ" or the bundle id.
    public var redirectScheme: String
    public var scopes: [String]

    public init(clientID: String, redirectScheme: String,
                scopes: [String] = ["https://www.googleapis.com/auth/contacts",
                                    "openid", "email"]) {
        self.clientID = clientID
        self.redirectScheme = redirectScheme
        self.scopes = scopes
    }

    public var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }

    public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

public enum OAuthError: Error, Equatable {
    case invalidCallback
    case tokenEndpoint(String)
    case noRefreshToken
    case notConnected
}

public final class GoogleOAuthClient: @unchecked Sendable {
    private let config: GoogleOAuthConfig
    private let session: URLSession
    private let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let revokeEndpoint = "https://oauth2.googleapis.com/revoke"

    public init(config: GoogleOAuthConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - PKCE

    public struct PendingAuthorization: Sendable {
        public var url: URL
        public var codeVerifier: String
        public var state: String
    }

    public func makeAuthorization() -> PendingAuthorization {
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Self.s256(verifier)
        let state = Self.randomURLSafe(bytes: 16)
        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return PendingAuthorization(url: comps.url!, codeVerifier: verifier, state: state)
    }

    public func exchangeCode(callbackURL: URL, pending: PendingAuthorization) async throws -> OAuthTokens {
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              comps.queryItems?.first(where: { $0.name == "state" })?.value == pending.state
        else { throw OAuthError.invalidCallback }

        return try await tokenRequest([
            "client_id": config.clientID,
            "code": code,
            "code_verifier": pending.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI
        ], existingRefreshToken: nil)
    }

    public func refresh(tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.noRefreshToken }
        var refreshed = try await tokenRequest([
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ], existingRefreshToken: refreshToken)
        refreshed.email = refreshed.email ?? tokens.email
        return refreshed
    }

    public func revoke(tokens: OAuthTokens) async {
        var req = URLRequest(url: URL(string: revokeEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "token=\(tokens.refreshToken ?? tokens.accessToken)".data(using: .utf8)
        _ = try? await session.data(for: req)
    }

    private func tokenRequest(_ params: [String: String],
                              existingRefreshToken: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw OAuthError.tokenEndpoint(String(data: data, encoding: .utf8) ?? "unknown")
        }
        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let email = Self.emailFromIDToken(json["id_token"] as? String)
        return OAuthTokens(accessToken: accessToken,
                           refreshToken: (json["refresh_token"] as? String) ?? existingRefreshToken,
                           expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                           email: email)
    }

    // MARK: - Helpers

    static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { buf in
            SecRandomCopyBytesShim(buf.baseAddress!, bytes)
        }
        return base64URL(data)
    }

    static func s256(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Best-effort decode of the id_token payload for the account email (no signature
    /// verification needed — token came straight from Google over TLS).
    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?/:")
        return set
    }()
}

#if canImport(Security)
import Security
@discardableResult
func SecRandomCopyBytesShim(_ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int32 {
    SecRandomCopyBytes(kSecRandomDefault, count, ptr)
}
#else
@discardableResult
func SecRandomCopyBytesShim(_ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int32 {
    let buf = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count { buf[i] = UInt8.random(in: 0...255) }
    return 0
}
#endif
