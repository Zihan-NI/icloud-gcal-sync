import Foundation
import SQLite3
import SyncCore

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLite error \(code): \(message)" }
}

public struct SchemaVersionError: Error, CustomStringConvertible, Equatable {
    public let found: Int
    public let supported: Int
    public var description: String {
        "Database schema version \(found) is newer than this build supports (\(supported)); refusing to open it"
    }
}

// sqlite3_bind_text needs the destructor constant as a function pointer; the C macro is not imported.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStateStore: SyncStateStore {
    /// Ordered migrations; index i brings the schema from version i to i+1.
    private static let migrations: [[String]] = [
        [
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            """
            CREATE TABLE links(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              origin TEXT NOT NULL, mode TEXT NOT NULL,
              apple_key TEXT NOT NULL UNIQUE,
              apple_calendar_id TEXT NOT NULL, apple_external_id TEXT NOT NULL, apple_local_id TEXT NOT NULL,
              occurrence TEXT,
              google_event_id TEXT NOT NULL UNIQUE,
              apple_hash TEXT NOT NULL, google_hash TEXT NOT NULL,
              start_ts REAL NOT NULL, last_synced_at REAL NOT NULL)
            """,
            "CREATE TABLE google_events(id TEXT PRIMARY KEY, json TEXT NOT NULL)",
        ],
    ]

    private var db: OpaquePointer?
    private var depth = 0

    // Dates as Double seconds: Swift prints the shortest decimal that parses back to the same
    // Double, so fractional seconds survive a round trip bit-for-bit.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create the file ourselves with 0600 so it is never briefly world-readable.
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot create \(url.path)")
            }
        }
        try open(path: url.path)
        let mode = try queryText("PRAGMA journal_mode=WAL")
        // SQLite silently keeps the old mode when WAL is unsupported (e.g. some network volumes).
        guard mode?.lowercased() == "wal" else {
            throw SQLiteError(code: SQLITE_ERROR, message: "could not enable WAL journal mode (got \(mode ?? "nothing"))")
        }
        try finishSetup()
        // WAL/SHM side files inherit the main file's mode, but be explicit.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private init(memory: Void) throws {
        try open(path: ":memory:")
        try finishSetup()
    }

    public static func inMemory() throws -> SQLiteStateStore { try SQLiteStateStore(memory: ()) }

    deinit { sqlite3_close(db) }

    private func open(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        db = handle
        guard rc == SQLITE_OK else {
            let err = SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            db = nil
            throw err
        }
    }

    private func finishSetup() throws {
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    private func migrate() throws {
        let target = Self.migrations.count
        let peek = try queryInt("PRAGMA user_version")
        if peek > target { throw SchemaVersionError(found: peek, supported: target) }
        guard peek < target else { return }
        try transaction {
            // Re-read under the write lock: another process may have migrated since the peek above.
            let current = try queryInt("PRAGMA user_version")
            if current > target { throw SchemaVersionError(found: current, supported: target) }
            guard current < target else { return }
            for v in current..<target {
                for sql in Self.migrations[v] { try exec(sql) }
            }
            // PRAGMA does not accept bound parameters.
            try exec("PRAGMA user_version=\(target)")
        }
    }

    // MARK: SQLite helpers

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    private func queryInt(_ sql: String) throws -> Int {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func queryText(_ sql: String) throws -> String? {
        try withStatement(sql) { stmt in
            sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
        }
    }

    private enum Arg {
        case text(String), real(Double), int(Int64), null
    }

    private func withStatement<T>(_ sql: String, _ args: [Arg] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { sqlite3_finalize(stmt); throw error(rc) }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch a {
            case .text(let s): brc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .real(let d): brc = sqlite3_bind_double(stmt, idx, d)
            case .int(let n): brc = sqlite3_bind_int64(stmt, idx, n)
            case .null: brc = sqlite3_bind_null(stmt, idx)
            }
            guard brc == SQLITE_OK else { throw error(brc) }
        }
        return try body(stmt)
    }

    /// Runs a statement that returns no rows; returns the number of rows changed.
    @discardableResult
    private func run(_ sql: String, _ args: [Arg] = []) throws -> Int {
        try withStatement(sql, args) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
            return Int(sqlite3_changes(db))
        }
    }

    private func rows<T>(_ sql: String, _ args: [Arg] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql, args) { stmt in
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error(rc) }
                out.append(try map(stmt))
            }
            return out
        }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, col))
    }

    // MARK: Transactions

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 {
            // Nested: join the outer transaction. A throw propagates; the outer body decides
            // whether to catch it (work already done stays) or let it roll everything back.
            depth += 1
            defer { depth -= 1 }
            return try body()
        }
        try exec("BEGIN IMMEDIATE")
        depth = 1
        defer { depth = 0 }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            // If COMMIT itself failed the transaction may still be open; ROLLBACK errors are moot then.
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        try rows("SELECT value FROM meta WHERE key=?", [.text(key)]) { text($0, 0) }.first ?? nil
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    [.text(key), .text(value)])
        } else {
            try run("DELETE FROM meta WHERE key=?", [.text(key)])
        }
    }

    // MARK: Links

    private static let linkColumns = """
        id, origin, mode, apple_key, apple_calendar_id, apple_external_id, apple_local_id, occurrence,
        google_event_id, apple_hash, google_hash, start_ts, last_synced_at
        """

    private func linkArgs(_ l: Link) -> [Arg] {
        [.text(l.origin.rawValue), .text(l.mode.rawValue), .text(l.appleKey), .text(l.appleCalendarID),
         .text(l.appleExternalID), .text(l.appleLocalID), l.occurrence.map { .text($0) } ?? .null,
         .text(l.googleEventID), .text(l.appleHash), .text(l.googleHash), .real(l.startTS),
         .real(l.lastSyncedAt.timeIntervalSince1970)]
    }

    private func readLink(_ s: OpaquePointer) throws -> Link {
        guard let origin = Link.Origin(rawValue: text(s, 1) ?? ""), let mode = Link.Mode(rawValue: text(s, 2) ?? "") else {
            throw SQLiteError(code: SQLITE_CORRUPT, message: "links row \(sqlite3_column_int64(s, 0)) has unknown origin or mode")
        }
        return Link(id: sqlite3_column_int64(s, 0), origin: origin, mode: mode, appleKey: text(s, 3) ?? "",
                    appleCalendarID: text(s, 4) ?? "", appleExternalID: text(s, 5) ?? "", appleLocalID: text(s, 6) ?? "",
                    occurrence: text(s, 7), googleEventID: text(s, 8) ?? "", appleHash: text(s, 9) ?? "",
                    googleHash: text(s, 10) ?? "", startTS: sqlite3_column_double(s, 11),
                    lastSyncedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 12)))
    }

    public func allLinks() throws -> [Link] {
        try rows("SELECT \(Self.linkColumns) FROM links ORDER BY id") { try readLink($0) }
    }

    public func insertLink(_ link: Link) throws -> Link {
        try run("""
            INSERT INTO links(origin, mode, apple_key, apple_calendar_id, apple_external_id, apple_local_id,
              occurrence, google_event_id, apple_hash, google_hash, start_ts, last_synced_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, linkArgs(link))
        var out = link
        out.id = sqlite3_last_insert_rowid(db)
        return out
    }

    public func updateLink(_ link: Link) throws {
        guard let id = link.id else { throw SQLiteError(code: SQLITE_MISUSE, message: "updateLink: link has no id") }
        let n = try run("""
            UPDATE links SET origin=?, mode=?, apple_key=?, apple_calendar_id=?, apple_external_id=?,
              apple_local_id=?, occurrence=?, google_event_id=?, apple_hash=?, google_hash=?, start_ts=?,
              last_synced_at=? WHERE id=?
            """, linkArgs(link) + [.int(id)])
        if n == 0 { throw SQLiteError(code: SQLITE_NOTFOUND, message: "updateLink: no link with id \(id)") }
    }

    public func deleteLink(id: Int64) throws {
        try run("DELETE FROM links WHERE id=?", [.int(id)])
    }

    // MARK: Google events

    public func allGoogleEvents() throws -> [GoogleEvent] {
        try rows("SELECT json FROM google_events ORDER BY id") { s in
            try decoder.decode(GoogleEvent.self, from: Data((text(s, 0) ?? "").utf8))
        }
    }

    public func upsertGoogleEvent(_ event: GoogleEvent) throws {
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        try run("INSERT INTO google_events(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                [.text(event.id), .text(json)])
    }

    public func deleteGoogleEvent(id: String) throws {
        try run("DELETE FROM google_events WHERE id=?", [.text(id)])
    }

    public func replaceGoogleEvents(_ events: [GoogleEvent]) throws {
        try transaction {
            try run("DELETE FROM google_events")
            for e in events { try upsertGoogleEvent(e) }
        }
    }
}
