import Foundation
import SQLite3

/// Stores metadata, never photo bytes. The app opens the file once and every screen shares that
/// one connection; a lock keeps calls from the main thread and background work apart.
final class InventoryStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let sharedLock = NSLock()
    private static var shared: InventoryStore?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            let failure = error()
            sqlite3_close(database)
            database = nil
            throw failure
        }
        try execute("CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS activity (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, message TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS archived (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, payload TEXT NOT NULL)")
    }

    deinit { sqlite3_close(database) }

    /// The app's own inventory, opened once and reused.
    static func openDefault() throws -> InventoryStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let store = try openFile()
        shared = store
        return store
    }

    private static func openFile() throws -> InventoryStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SmartPhotoVault", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try InventoryStore(url: directory.appendingPathComponent("inventory.sqlite"))
    }

    /// Call off the main thread: a large scan takes a while to encode.
    func save(_ snapshot: ScanSnapshot) throws {
        // Encoded before taking the lock, so other screens' log writes aren't held up meanwhile.
        let json = try JSONEncoder().encode(snapshot)
        let summary = "Scan saved: \(snapshot.assets.count) assets, \(snapshot.verifiedCount) fully hashed, \(snapshot.duplicateGroupCount) duplicate groups."
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT OR REPLACE INTO snapshot(id,payload) VALUES(1,?)")
            defer { sqlite3_finalize(statement) }
            // Still stored as TEXT, bound straight from the encoded bytes without another copy.
            let bound = json.withUnsafeBytes { raw in
                sqlite3_bind_text(statement, 1, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count), transient)
            }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            try log(summary)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Call off the main thread: a large scan takes a while to decode.
    func load() throws -> ScanSnapshot? {
        // Decoded after the lock is released, so other screens' log writes aren't held up meanwhile.
        guard let data = try savedPayload() else { return nil }
        return try JSONDecoder().decode(ScanSnapshot.self, from: data)
    }

    /// The stored scan's bytes, copied once.
    private func savedPayload() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM snapshot WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_blob(statement, 0) else { throw error() }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func log(_ message: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("INSERT INTO activity(timestamp,message) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, message, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func saveArchived(_ records: [ArchivedRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        for record in records {
            let json = String(decoding: try encoder.encode(record), as: UTF8.self)
            let statement = try prepare("INSERT OR REPLACE INTO archived(id,timestamp,payload) VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, record.id, -1, transient)
            sqlite3_bind_double(statement, 2, record.date.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, json, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    /// Total size of everything archived, without loading every record.
    func archivedBytes() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        // A Live Photo or edited photo also counts its other files; older records have none.
        let statement = try prepare("SELECT (SELECT COALESCE(SUM(json_extract(payload, '$.bytes')), 0) FROM archived) + (SELECT COALESCE(SUM(json_extract(part.value, '$.bytes')), 0) FROM archived AS item, json_each(item.payload, '$.parts') AS part)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(statement, 0)
    }

    func archivedCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM archived")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Every archived copy, newest first. No limit: an older copy must never drop out of Get back.
    func archived() throws -> [ArchivedRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM archived ORDER BY timestamp DESC, id")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var records: [ArchivedRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw error() }
            // One copy of the stored bytes. An empty payload has no pointer; it fails to decode and is skipped, as before.
            let data = sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 0))) } ?? Data()
            if let record = try? decoder.decode(ArchivedRecord.self, from: data) {
                records.append(record)
            }
        }
    }

    func activity() throws -> [ActivityEntry] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT id,timestamp,message FROM activity ORDER BY id DESC LIMIT 100")
        defer { sqlite3_finalize(statement) }
        var entries: [ActivityEntry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return entries }
            guard status == SQLITE_ROW, let message = sqlite3_column_text(statement, 2) else { throw error() }
            entries.append(ActivityEntry(id: sqlite3_column_int64(statement, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), message: String(cString: message)))
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func error() -> NSError {
        NSError(domain: "InventoryStore", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
