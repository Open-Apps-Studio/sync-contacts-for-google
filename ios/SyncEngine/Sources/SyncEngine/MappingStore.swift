import Foundation

/// Durable engine state: identity map + base snapshots, sync cursors, the activity
/// log, and the resumable work queue. One SQLite file in the app container.
public final class MappingStore {
    private let db: SQLiteDatabase
    // Foundation's JSONEncoder/JSONDecoder are not safe for concurrent use, and this
    // store is touched from both the SyncOrchestrator actor and the main actor. Use a
    // fresh coder per call (cheap) rather than sharing one across threads.

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS mapping (
                local_id TEXT PRIMARY KEY,
                remote_name TEXT NOT NULL UNIQUE,
                remote_etag TEXT NOT NULL,
                base_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS cursors (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS activity (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                detail TEXT
            )
            """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS work_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL
            )
            """)
    }

    // MARK: - Mappings

    public func upsert(_ mapping: Mapping) throws {
        let base = try JSONEncoder().encode(mapping.base)
        try db.exec("""
            INSERT INTO mapping (local_id, remote_name, remote_etag, base_json, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
                remote_name = excluded.remote_name,
                remote_etag = excluded.remote_etag,
                base_json = excluded.base_json,
                updated_at = excluded.updated_at
            """, [.text(mapping.localID), .text(mapping.remoteResourceName),
                  .text(mapping.remoteEtag), .blob(base),
                  .int(Int64(mapping.updatedAt.timeIntervalSince1970))])
    }

    public func mapping(forLocalID id: String) throws -> Mapping? {
        try db.query("SELECT * FROM mapping WHERE local_id = ?", [.text(id)])
            .first.flatMap(rowToMapping)
    }

    public func mapping(forRemoteName name: String) throws -> Mapping? {
        try db.query("SELECT * FROM mapping WHERE remote_name = ?", [.text(name)])
            .first.flatMap(rowToMapping)
    }

    public func allMappings() throws -> [Mapping] {
        try db.query("SELECT * FROM mapping").compactMap(rowToMapping)
    }

    public func deleteMapping(localID: String) throws {
        try db.exec("DELETE FROM mapping WHERE local_id = ?", [.text(localID)])
    }

    public func deleteAllMappings() throws {
        try db.exec("DELETE FROM mapping")
    }

    private func rowToMapping(_ row: [String: SQLiteDatabase.Value]) -> Mapping? {
        guard let localID = row["local_id"]?.stringValue,
              let remoteName = row["remote_name"]?.stringValue,
              let etag = row["remote_etag"]?.stringValue,
              let baseData = row["base_json"]?.blobValue,
              let ts = row["updated_at"]?.intValue,
              let base = try? JSONDecoder().decode(SyncContact.self, from: baseData)
        else { return nil }
        return Mapping(localID: localID, remoteResourceName: remoteName, remoteEtag: etag,
                       base: base, updatedAt: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - Cursors (sync tokens, history tokens, timestamps)

    public func cursor(_ key: String) throws -> String? {
        try db.query("SELECT value FROM cursors WHERE key = ?", [.text(key)])
            .first?["value"]?.stringValue
    }

    public func setCursor(_ key: String, _ value: String?) throws {
        if let value {
            try db.exec("""
                INSERT INTO cursors (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [.text(key), .text(value)])
        } else {
            try db.exec("DELETE FROM cursors WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Activity log

    @discardableResult
    public func log(_ event: ActivityEvent) throws -> Int64 {
        try db.exec("INSERT INTO activity (ts, kind, summary, detail) VALUES (?, ?, ?, ?)",
                    [.int(Int64(event.timestamp.timeIntervalSince1970)),
                     .text(event.kind.rawValue), .text(event.summary),
                     event.detail.map { .text($0) } ?? .null])
        return db.lastInsertRowID
    }

    public func recentActivity(limit: Int = 200) throws -> [ActivityEvent] {
        try db.query("SELECT * FROM activity ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])
            .compactMap { row in
                guard let id = row["id"]?.intValue,
                      let ts = row["ts"]?.intValue,
                      let kindRaw = row["kind"]?.stringValue,
                      let kind = ActivityKind(rawValue: kindRaw),
                      let summary = row["summary"]?.stringValue
                else { return nil }
                return ActivityEvent(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                                     kind: kind, summary: summary,
                                     detail: row["detail"]?.stringValue)
            }
    }

    public func pruneActivity(keeping limit: Int = 2000) throws {
        try db.exec("""
            DELETE FROM activity WHERE id NOT IN
            (SELECT id FROM activity ORDER BY id DESC LIMIT ?)
            """, [.int(Int64(limit))])
    }

    // MARK: - Resumable work queue

    public struct WorkItem: Codable, Equatable, Sendable {
        public var id: Int64 = 0
        public var kind: Kind
        public var payload: Data

        public enum Kind: String, Codable, Sendable {
            case createRemote, updateRemote, deleteRemote
            case createLocal, updateLocal, deleteLocal
        }

        public init(kind: Kind, payload: Data) {
            self.kind = kind
            self.payload = payload
        }
    }

    public func enqueue(_ item: WorkItem) throws {
        try db.exec("INSERT INTO work_queue (kind, payload, created_at) VALUES (?, ?, ?)",
                    [.text(item.kind.rawValue), .blob(item.payload),
                     .int(Int64(Date().timeIntervalSince1970))])
    }

    public func pendingWork(limit: Int = 500) throws -> [WorkItem] {
        try db.query("SELECT * FROM work_queue ORDER BY id ASC LIMIT ?", [.int(Int64(limit))])
            .compactMap { row in
                guard let id = row["id"]?.intValue,
                      let kindRaw = row["kind"]?.stringValue,
                      let kind = WorkItem.Kind(rawValue: kindRaw),
                      let payload = row["payload"]?.blobValue
                else { return nil }
                var item = WorkItem(kind: kind, payload: payload)
                item.id = id
                return item
            }
    }

    public func completeWork(id: Int64) throws {
        try db.exec("DELETE FROM work_queue WHERE id = ?", [.int(id)])
    }

    public func clearWorkQueue() throws {
        try db.exec("DELETE FROM work_queue")
    }
}
