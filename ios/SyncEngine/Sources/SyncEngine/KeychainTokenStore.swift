import Foundation
#if canImport(Security)
import Security

/// OAuth tokens in the Keychain, readable after first unlock so background wakes
/// (silent push / BGTask) can refresh and sync while the phone is locked.
public final class KeychainTokenStore: @unchecked Sendable {
    private let service: String
    private let account = "google-oauth"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.openappsstudio.contactssync") {
        self.service = service
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data = try encoder.encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func load() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? decoder.decode(OAuthTokens.self, from: data)
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Serializes token refresh so concurrent API calls don't race the refresh endpoint.
public actor TokenProvider {
    private let oauth: GoogleOAuthClient
    private let store: KeychainTokenStore
    private var cached: OAuthTokens?

    public init(oauth: GoogleOAuthClient, store: KeychainTokenStore) {
        self.oauth = oauth
        self.store = store
    }

    public func currentAccessToken() async throws -> String {
        var tokens = cached ?? store.load()
        guard var t = tokens else { throw OAuthError.notConnected }
        if t.isExpired {
            t = try await oauth.refresh(tokens: t)
            try store.save(t)
        }
        cached = t
        tokens = t
        return t.accessToken
    }

    public func adopt(_ tokens: OAuthTokens) throws {
        try store.save(tokens)
        cached = tokens
    }

    public func disconnectAndRevoke() async {
        if let t = cached ?? store.load() {
            await oauth.revoke(tokens: t)
        }
        store.clear()
        cached = nil
    }

    public var email: String? {
        get async { (cached ?? store.load())?.email }
    }

    public var isConnected: Bool {
        get async { (cached ?? store.load()) != nil }
    }
}
#endif
