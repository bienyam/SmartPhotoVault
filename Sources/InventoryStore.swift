import Foundation
import SQLite3

/// Accessed on the main actor by DashboardModel. Stores metadata, never photo bytes.
final class InventoryStore {
    private var database: OpaquePointer?
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
    }

    deinit { sqlite3_close(database) }

    static func openDefault() throws -> InventoryStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SmartPhotoVault", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try InventoryStore(url: directory.appendingPathComponent("inventory.sqlite"))
    }

    func save(_ snapshot: ScanSnapshot) throws {
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT OR REPLACE INTO snapshot(id,payload) VALUES(1,?)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, json, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            try log("Scan saved: \(snapshot.assets.count) assets, \(snapshot.verifiedCount) fully hashed, \(snapshot.groups.count) duplicate groups.")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func load() throws -> ScanSnapshot? {
        let statement = try prepare("SELECT payload FROM snapshot WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw error() }
        return try JSONDecoder().decode(ScanSnapshot.self, from: Data(String(cString: value).utf8))
    }

    func log(_ message: String) throws {
        let statement = try prepare("INSERT INTO activity(timestamp,message) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, message, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func activity() throws -> [ActivityEntry] {
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
