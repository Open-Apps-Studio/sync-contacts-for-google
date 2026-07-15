import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PeopleAPIError: Error, Equatable {
    case expiredSyncToken
    case rateLimited(retryAfterSeconds: Int?)
    case quotaExhausted
    case staleEtag
    case unauthorized
    case http(status: Int, message: String)
    case malformedResponse
}

public struct RemoteDelta: Sendable {
    public var records: [GoogleFieldMapper.PersonRecord]
    public var nextSyncToken: String?

    public init(records: [GoogleFieldMapper.PersonRecord], nextSyncToken: String?) {
        self.records = records
        self.nextSyncToken = nextSyncToken
    }
}

/// Abstraction over the Google People API — the orchestrator only sees this.
public protocol GooglePeopleAPI: Sendable {
    /// Incremental (or, with nil token, full) list of the user's contacts.
    func listConnections(syncToken: String?) async throws -> RemoteDelta
    /// Returns (resourceName, etag) for each created contact, in input order.
    func createContacts(_ contacts: [SyncContact]) async throws -> [(resourceName: String, etag: String)]
    /// Full-person update (etag required for optimistic concurrency).
    func updateContact(resourceName: String, etag: String,
                       contact: SyncContact, updateMask: [String]) async throws -> String
    func deleteContacts(resourceNames: [String]) async throws
}

/// URLSession-backed implementation. Access token comes from a provider closure so
/// the OAuth layer stays separate.
public final class GooglePeopleClient: GooglePeopleAPI, @unchecked Sendable {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private let tokenProvider: AccessTokenProvider
    private let session: URLSession
    private let base = URL(string: "https://people.googleapis.com/v1")!
    public static let createBatchLimit = 200
    public static let deleteBatchLimit = 500

    public init(tokenProvider: @escaping AccessTokenProvider, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - API calls

    public func listConnections(syncToken: String?) async throws -> RemoteDelta {
        var records: [GoogleFieldMapper.PersonRecord] = []
        var pageToken: String?
        var nextSyncToken: String?

        repeat {
            var comps = URLComponents(url: base.appendingPathComponent("people/me/connections"),
                                      resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "personFields", value: GoogleFieldMapper.personFields),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "requestSyncToken", value: "true")
            ]
            if let syncToken { items.append(URLQueryItem(name: "syncToken", value: syncToken)) }
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items

            let json = try await request("GET", comps.url!)
            let connections = json["connections"] as? [[String: Any]] ?? []
            records.append(contentsOf: connections.map(GoogleFieldMapper.fromPerson))
            pageToken = json["nextPageToken"] as? String
            if let t = json["nextSyncToken"] as? String { nextSyncToken = t }
        } while pageToken != nil

        return RemoteDelta(records: records, nextSyncToken: nextSyncToken)
    }

    public func createContacts(_ contacts: [SyncContact]) async throws -> [(resourceName: String, etag: String)] {
        var results: [(String, String)] = []
        for chunk in contacts.chunked(into: Self.createBatchLimit) {
            let body: [String: Any] = [
                "contacts": chunk.map { ["contactPerson": GoogleFieldMapper.toPerson($0)] },
                "readMask": "names,metadata"
            ]
            let url = base.appendingPathComponent("people:batchCreateContacts")
            let json = try await request("POST", url, body: body)
            let created = json["createdPeople"] as? [[String: Any]] ?? []
            guard created.count == chunk.count else { throw PeopleAPIError.malformedResponse }
            for entry in created {
                guard let person = entry["person"] as? [String: Any],
                      let name = person["resourceName"] as? String
                else { throw PeopleAPIError.malformedResponse }
                results.append((name, (person["etag"] as? String) ?? ""))
            }
        }
        return results
    }

    public func updateContact(resourceName: String, etag: String,
                              contact: SyncContact, updateMask: [String]) async throws -> String {
        var comps = URLComponents(url: base.appendingPathComponent("\(resourceName):updateContact"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "updatePersonFields",
                         value: updateMask.filter { GoogleFieldMapper.updatableFields.contains($0) }
                                          .joined(separator: ",")),
            URLQueryItem(name: "personFields", value: "metadata")
        ]
        let body = GoogleFieldMapper.toPerson(contact, etag: etag)
        let json = try await request("PATCH", comps.url!, body: body)
        return (json["etag"] as? String) ?? ""
    }

    public func deleteContacts(resourceNames: [String]) async throws {
        for chunk in resourceNames.chunked(into: Self.deleteBatchLimit) {
            let url = base.appendingPathComponent("people:batchDeleteContacts")
            _ = try await request("POST", url, body: ["resourceNames": chunk])
        }
    }

    // MARK: - Transport

    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil,
                         attempt: Int = 0) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PeopleAPIError.malformedResponse }

        switch http.statusCode {
        case 200...299:
            if data.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 401:
            throw PeopleAPIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            if attempt < 3 {
                let delay = retryAfter ?? Int(pow(2.0, Double(attempt + 1)))
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                return try await request(method, url, body: body, attempt: attempt + 1)
            }
            throw PeopleAPIError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            let message = Self.errorMessage(from: data)
            if Self.isExpiredSyncToken(status: http.statusCode, data: data) {
                throw PeopleAPIError.expiredSyncToken
            }
            if http.statusCode == 412 || message.contains("etag") {
                throw PeopleAPIError.staleEtag
            }
            if message.contains("RESOURCE_EXHAUSTED") || message.contains("Quota exceeded") {
                throw PeopleAPIError.quotaExhausted
            }
            throw PeopleAPIError.http(status: http.statusCode, message: message)
        }
    }

    static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return "" }
        let status = (error["status"] as? String) ?? ""
        let message = (error["message"] as? String) ?? ""
        return "\(status) \(message)"
    }

    static func isExpiredSyncToken(status: Int, data: Data) -> Bool {
        guard status == 400 || status == 410 else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return false }
        if let details = error["details"] as? [[String: Any]],
           details.contains(where: { ($0["reason"] as? String) == "EXPIRED_SYNC_TOKEN" }) {
            return true
        }
        return ((error["message"] as? String) ?? "").contains("Sync token")
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
