import XCTest
import SQLite3
@testable import SyncStorage
import SyncCore

final class SQLiteStateStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func link(_ n: Int, origin: Link.Origin = .apple, mode: Link.Mode = .twoWay, occurrence: String? = nil) -> Link {
        Link(origin: origin, mode: mode, appleKey: "cal|ext\(n)", appleCalendarID: "cal", appleExternalID: "ext\(n)",
             appleLocalID: "loc\(n)", occurrence: occurrence, googleEventID: "g\(n)", appleHash: "ah\(n)",
             googleHash: "gh\(n)", startTS: 1_700_000_000.25 + Double(n), lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_100.5))
    }

    func testReopenKeepsData() throws {
        let url = dir.appendingPathComponent("sub/state.db")
        do {
            let s = try SQLiteStateStore(url: url)
            try s.setMeta("k", "v")
            _ = try s.insertLink(link(1))
        }
        let s = try SQLiteStateStore(url: url)
        XCTAssertEqual(try s.meta("k"), "v")
        XCTAssertEqual(try s.allLinks().count, 1)
    }

    func testFileMode() throws {
        let url = dir.appendingPathComponent("state.db")
        _ = try SQLiteStateStore(url: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWALEnabledAndSideFilesPrivate() throws {
        let url = dir.appendingPathComponent("state.db")
        let s = try SQLiteStateStore(url: url)
        try s.setMeta("k", "v") // forces -wal/-shm to exist while the store is open
        for suffix in ["-wal", "-shm"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
            XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600, suffix)
        }
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &h), SQLITE_OK)
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(h, "PRAGMA journal_mode", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "wal")
    }

    func testPreexistingLooseFileModeTightened() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.db")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
        _ = try SQLiteStateStore(url: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testNewerUserVersionRejected() throws {
        let url = dir.appendingPathComponent("state.db")
        _ = try SQLiteStateStore(url: url)
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &h), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(h, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(h)
        XCTAssertThrowsError(try SQLiteStateStore(url: url)) { e in
            XCTAssertEqual(e as? SchemaVersionError, SchemaVersionError(found: 99, supported: 1))
        }
    }

    func testMeta() throws {
        let s = try SQLiteStateStore.inMemory()
        XCTAssertNil(try s.meta("a"))
        try s.setMeta("a", "1")
        try s.setMeta("a", "2")
        XCTAssertEqual(try s.meta("a"), "2")
        try s.setMeta("a", nil)
        XCTAssertNil(try s.meta("a"))
        try s.setMeta("missing", nil)
    }

    func testLinkRoundTrip() throws {
        let s = try SQLiteStateStore.inMemory()
        let a = try s.insertLink(link(1, origin: .apple, mode: .twoWay, occurrence: nil))
        let b = try s.insertLink(link(2, origin: .google, mode: .oneWay, occurrence: "2026-01-01T10:00:00+00:00"))
        XCTAssertNotNil(a.id)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try s.allLinks(), [a, b])

        var c = b
        c.appleHash = "new"; c.occurrence = nil; c.mode = .twoWay; c.startTS = 5.125
        c.lastSyncedAt = Date(timeIntervalSince1970: 42.75)
        try s.updateLink(c)
        XCTAssertEqual(try s.allLinks(), [a, c])

        try s.deleteLink(id: a.id!)
        XCTAssertEqual(try s.allLinks(), [c])
        try s.deleteLink(id: 9999)
    }

    func testUpdateMissingThrows() throws {
        let s = try SQLiteStateStore.inMemory()
        var l = link(1); l.id = 77
        XCTAssertThrowsError(try s.updateLink(l))
        XCTAssertThrowsError(try s.updateLink(link(1)))
    }

    func testUniqueConstraints() throws {
        let s = try SQLiteStateStore.inMemory()
        _ = try s.insertLink(link(1))
        var dupApple = link(2); dupApple.appleKey = link(1).appleKey
        XCTAssertThrowsError(try s.insertLink(dupApple)) { e in
            XCTAssertTrue("\(e)".contains("links.apple_key"), "\(e)")
        }
        var dupGoogle = link(3); dupGoogle.googleEventID = "g1"
        XCTAssertThrowsError(try s.insertLink(dupGoogle)) { e in
            XCTAssertTrue("\(e)".contains("links.google_event_id"), "\(e)")
        }
    }

    func testGoogleEvents() throws {
        let s = try SQLiteStateStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let timed = GoogleEvent(id: "t", content: EventContent(title: "T", timing: .timed(start: t0, end: t0.addingTimeInterval(3600.987)),
                                location: "L", notes: "N", isFree: true, timeZoneID: "America/New_York"),
                                updated: Date(timeIntervalSince1970: 1_700_000_500.5), isRecurring: true, mirrorKey: "k")
        let allDay = GoogleEvent(id: "a", content: EventContent(title: "A", timing: .allDay(startDay: "2026-03-01", endDayExclusive: "2026-03-02")))
        let none = GoogleEvent(id: "n", content: nil, isCancelled: true)
        for e in [timed, allDay, none] { try s.upsertGoogleEvent(e) }
        XCTAssertEqual(try s.allGoogleEvents().sorted { $0.id < $1.id }, [allDay, none, timed])

        var changed = allDay; changed.content?.title = "A2"
        try s.upsertGoogleEvent(changed)
        XCTAssertEqual(try s.allGoogleEvents().count, 3)
        try s.deleteGoogleEvent(id: "n")
        try s.deleteGoogleEvent(id: "nope")
        XCTAssertEqual(try s.allGoogleEvents().map(\.id).sorted(), ["a", "t"])

        try s.replaceGoogleEvents([none])
        XCTAssertEqual(try s.allGoogleEvents(), [none])
        try s.replaceGoogleEvents([])
        XCTAssertEqual(try s.allGoogleEvents(), [])
    }

    struct Boom: Error {}

    func testTransactionCommitAndRollback() throws {
        let s = try SQLiteStateStore.inMemory()
        let r = try s.transaction { () -> Int in try s.setMeta("a", "1"); return 7 }
        XCTAssertEqual(r, 7)
        XCTAssertEqual(try s.meta("a"), "1")

        XCTAssertThrowsError(try s.transaction { try s.setMeta("b", "1"); throw Boom() }) { XCTAssertTrue($0 is Boom) }
        XCTAssertNil(try s.meta("b"))
        // Store is usable after a rollback.
        try s.setMeta("c", "1")
        XCTAssertEqual(try s.meta("c"), "1")
    }

    func testNestedTransactions() throws {
        let s = try SQLiteStateStore.inMemory()
        try s.transaction {
            try s.setMeta("outer", "1")
            do { try s.transaction { try s.setMeta("inner", "1"); throw Boom() } } catch {}
            try s.transaction { try s.setMeta("inner2", "1") }
        }
        XCTAssertEqual(try s.meta("outer"), "1")
        XCTAssertEqual(try s.meta("inner"), "1")
        XCTAssertEqual(try s.meta("inner2"), "1")

        XCTAssertThrowsError(try s.transaction {
            try s.transaction { try s.setMeta("x", "1") }
            throw Boom()
        })
        XCTAssertNil(try s.meta("x"))
    }

    func testDatesRoundTripExactly() throws {
        let s = try SQLiteStateStore.inMemory()
        var originals: [GoogleEvent] = []
        var links: [Link] = []
        for n in 0..<500 {
            let a = Date(timeIntervalSince1970: Double.random(in: 0...2_000_000_000))
            let b = Date(timeIntervalSince1970: Double.random(in: 0...2_000_000_000))
            let e = GoogleEvent(id: String(format: "e%04d", n), content: EventContent(title: "x", timing: .timed(start: a, end: b)), updated: b)
            try s.upsertGoogleEvent(e)
            originals.append(e)
            var l = link(n); l.lastSyncedAt = a
            links.append(try s.insertLink(l))
        }
        XCTAssertEqual(try s.allGoogleEvents(), originals)
        XCTAssertEqual(try s.allLinks(), links)
    }
}
