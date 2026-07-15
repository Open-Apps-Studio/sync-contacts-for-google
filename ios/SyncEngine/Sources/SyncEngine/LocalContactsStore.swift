import Foundation

/// One contact as it exists in the device store right now.
public struct LocalContact: Equatable, Sendable {
    public var id: String
    public var contact: SyncContact

    public init(id: String, contact: SyncContact) {
        self.id = id
        self.contact = contact
    }
}

/// Abstraction over CNContactStore — the orchestrator only sees this.
/// The engine uses full-state comparison against its mapping table, so no
/// change-history plumbing is required for correctness (the shim is a fast path
/// the app can use to decide *whether* to sync).
public protocol LocalContactsStore: Sendable {
    /// Every syncable contact in the writable container (non-unified).
    func fetchAll() async throws -> [LocalContact]
    /// Returns the new local IDs, in input order.
    func create(_ contacts: [SyncContact]) async throws -> [String]
    func update(id: String, contact: SyncContact) async throws
    func delete(ids: [String]) async throws
    /// Total contacts visible to the app (for the deletion guard denominator).
    func count() async throws -> Int
}
