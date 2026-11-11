import SyncCore
import SyncStorage
import XCTest

final class EngineTests: XCTestCase {
    var apple: FakeApple!
    var google: FakeGoogle!
    var store: SQLiteStateStore!
    var config = SyncConfig()

    override func setUpWithError() throws {
        apple = FakeApple()
        google = FakeGoogle()
        store = try SQLiteStateStore.inMemory()
        config = SyncConfig()
    }

    @discardableResult
    func sync(dryRun: Bool = false, allowMassDelete: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> SyncEngine.Report {
        let engine = SyncEngine(apple: apple, google: google, store: store, config: config, now: { testNow }, timeZone: utc)
        return try engine.runOnce(.init(dryRun: dryRun, allowMassDelete: allowMassDelete))
    }

    /// After any scenario the system must be at rest: another run changes nothing.
    func assertQuiet(file: StaticString = #filePath, line: UInt = #line) throws {
        let aw = apple.writes, gw = google.writes
        let report = try sync()
        XCTAssertEqual(apple.writes, aw, "Apple was written again", file: file, line: line)
        XCTAssertEqual(google.writes, gw, "Google was written again", file: file, line: line)
        XCTAssertFalse(report.plan.actions.contains { $0.writesCalendar }, "plan not empty: \(report.plan.summary)", file: file, line: line)
    }

    // MARK: Apple → Google

    func testAppleEventIsCopiedOnceAndOwnWriteIsNotAnEcho() throws {
        let a = apple.add(timed("Dentist", location: "Main St"))
        try sync()
        XCTAssertEqual(google.events.count, 1)
        let g = google.events.values.first!
        XCTAssertEqual(g.mirrorKey, a.key)
        XCTAssertEqual(g.content?.title, "Dentist")
        XCTAssertEqual(try store.allLinks().first?.mode, .twoWay)
        XCTAssertEqual(try store.allLinks().first?.origin, .apple)
        try assertQuiet()
    }

    func testAppleEditAndDeletePropagate() throws {
        let a = apple.add(timed("Lunch"))
        try sync()
        apple.edit(a.localID) { $0.title = "Lunch with Sam"; $0.location = "Cafe" }
        try sync()
        XCTAssertEqual(google.events.values.first?.content?.title, "Lunch with Sam")
        XCTAssertEqual(google.events.values.first?.content?.location, "Cafe")
        try assertQuiet()
        apple.remove(a.localID)
        try sync()
        XCTAssertTrue(google.events.isEmpty)
        XCTAssertTrue(try store.allLinks().isEmpty)
        try assertQuiet()
    }

    // MARK: Google → Apple

    func testEventCreatedInGoogleLandsInAppleTargetCalendar() throws {
        let g = google.userCreate(timed("Flight to SFO", notes: "UA 123"))
        try sync()
        XCTAssertEqual(apple.events.count, 1)
        let a = apple.events.values.first!
        XCTAssertEqual(a.calendarID, FakeApple.targetCalendar)
        XCTAssertEqual(a.content.notes, "UA 123")
        XCTAssertNil(google.events[g.id]?.mirrorKey, "an event created in Google must stay unmarked")
        XCTAssertEqual(google.writes, 0)
        XCTAssertEqual(try store.allLinks().first?.origin, .google)
        try assertQuiet()
    }

    func testGoogleEditAndDeleteOfGoogleEventPropagate() throws {
        let g = google.userCreate(timed("Gym"))
        try sync()
        google.userEdit(g.id) { $0.title = "Gym (legs)" }
        try sync()
        XCTAssertEqual(apple.events.values.first?.content.title, "Gym (legs)")
        try assertQuiet()
        google.userDelete(g.id)
        try sync()
        XCTAssertTrue(apple.events.isEmpty)
        try assertQuiet()
    }

    func testAppleEditOfGoogleEventGoesBackWithoutMarkingIt() throws {
        let g = google.userCreate(timed("Call"))
        try sync()
        let a = apple.events.values.first!
        apple.edit(a.localID) { $0.title = "Call Mom" }
        try sync()
        XCTAssertEqual(google.events[g.id]?.content?.title, "Call Mom")
        XCTAssertNil(google.events[g.id]?.mirrorKey)
        try assertQuiet()
    }

    func testGoogleEditOfMirroredSingleEventUpdatesApple() throws {
        let a = apple.add(timed("Review"))
        try sync()
        let id = google.events.keys.first!
        google.userEdit(id) { $0.timing = .timed(start: day(2), end: day(2).addingTimeInterval(1800)) }
        try sync()
        XCTAssertEqual(apple.events[a.localID]?.content.timing, .timed(start: day(2), end: day(2).addingTimeInterval(1800)))
        try assertQuiet()
    }

    func testGoogleDeleteOfMirroredSingleEventDeletesApple() throws {
        apple.add(timed("Old plan"))
        try sync()
        google.userDelete(google.events.keys.first!)
        try sync()
        XCTAssertTrue(apple.events.isEmpty)
        try assertQuiet()
    }

    // MARK: Recurring events stay one-way

    func testRecurringOccurrenceIsOneWay() throws {
        let a = apple.add(timed("Standup"), occurrence: "2026-06-16T10:00:00+00:00", recurring: true)
        try sync()
        XCTAssertEqual(try store.allLinks().first?.mode, .oneWay)
        let id = google.events.keys.first!

        google.userEdit(id) { $0.title = "changed in Google" }
        try sync()
        XCTAssertEqual(apple.events[a.localID]?.content.title, "Standup", "a recurring event must never be written from Google")
        XCTAssertEqual(apple.writes, 0)

        apple.edit(a.localID) { $0.location = "Room 2" }
        try sync()
        XCTAssertEqual(google.events[id]?.content?.title, "Standup")
        XCTAssertEqual(google.events[id]?.content?.location, "Room 2")

        google.userDelete(id)
        try sync()
        XCTAssertEqual(apple.events.count, 1, "deleting the copy of a recurring event must not delete the original")
        XCTAssertEqual(google.events.count, 1, "the copy is restored")
        try assertQuiet()
    }

    func testRecurringEventCreatedInGoogleIsSkipped() throws {
        google.userCreate(timed("Weekly"), recurring: true)
        let report = try sync()
        XCTAssertTrue(apple.events.isEmpty)
        XCTAssertEqual(report.plan.skippedRecurringGoogle, 1)
    }

    func testReadOnlyCalendarIsOneWay() throws {
        let a = apple.add(timed("Shared"), readOnly: true)
        try sync()
        XCTAssertEqual(try store.allLinks().first?.mode, .oneWay)
        google.userDelete(google.events.keys.first!)
        try sync()
        XCTAssertNotNil(apple.events[a.localID])
        XCTAssertEqual(apple.writes, 0)
    }

    // MARK: Conflicts

    func testBothEditedNewestWins() throws {
        let a = apple.add(timed("Plan"))
        try sync()
        let id = google.events.keys.first!
        apple.edit(a.localID, modified: day(0, hour: 9)) { $0.title = "Plan A" }
        google.userEdit(id, updated: day(0, hour: 11)) { $0.title = "Plan G" }
        let report = try sync()
        XCTAssertEqual(apple.events[a.localID]?.content.title, "Plan G")
        XCTAssertEqual(report.plan.conflicts.count, 1)
        try assertQuiet()
    }

    func testBothEditedAppleWinsWhenOlderGoogleOrPolicyApple() throws {
        let a = apple.add(timed("Plan"))
        try sync()
        let id = google.events.keys.first!
        apple.edit(a.localID, modified: day(0, hour: 11)) { $0.title = "Plan A" }
        google.userEdit(id, updated: day(0, hour: 9)) { $0.title = "Plan G" }
        try sync()
        XCTAssertEqual(google.events[id]?.content?.title, "Plan A")

        config.conflictPolicy = .apple
        apple.edit(a.localID, modified: day(0, hour: 9)) { $0.title = "Plan A2" }
        google.userEdit(id, updated: day(0, hour: 11)) { $0.title = "Plan G2" }
        try sync()
        XCTAssertEqual(google.events[id]?.content?.title, "Plan A2")
        try assertQuiet()
    }

    func testBothEditedToTheSameContentIsNotAConflict() throws {
        let a = apple.add(timed("Same"))
        try sync()
        apple.edit(a.localID) { $0.title = "Same!" }
        google.userEdit(google.events.keys.first!) { $0.title = "Same!" }
        let report = try sync()
        XCTAssertTrue(report.plan.conflicts.isEmpty)
        XCTAssertEqual(apple.writes, 0)
        XCTAssertEqual(google.writes, 1, "only the original insert")
        try assertQuiet()
    }

    func testEditBeatsDeleteInBothDirections() throws {
        let a = apple.add(timed("Keep me"))
        let g2 = google.userCreate(timed("Keep me too"))
        try sync()
        let mirrorID = google.events.values.first { $0.mirrorKey != nil }!.id
        // Deleted in Google, edited in Apple: the Apple edit survives.
        google.userDelete(mirrorID)
        apple.edit(a.localID) { $0.title = "Keep me (edited)" }
        // Deleted in Apple, edited in Google: the Google edit survives.
        let a2 = apple.events.values.first { $0.calendarID == FakeApple.targetCalendar }!
        apple.remove(a2.localID)
        google.userEdit(g2.id) { $0.title = "Keep me too (edited)" }
        try sync()
        XCTAssertEqual(apple.events.count, 2)
        XCTAssertEqual(google.events.count, 2)
        XCTAssertTrue(google.events.values.contains { $0.content?.title == "Keep me (edited)" })
        XCTAssertTrue(apple.events.values.contains { $0.content.title == "Keep me too (edited)" })
        try assertQuiet()
    }

    // MARK: Loop prevention under lossy storage

    func testNoPingPongWhenEachSideStoresTheEventDifferently() throws {
        apple.dropsFreeFlag = true
        google.rewrite = { var c = $0; c.notes = ($0.notes ?? "") + "\n<br>added by Google"; return c }
        var busyFree = timed("Lossy")
        busyFree.isFree = true
        google.userCreate(busyFree)          // Apple will drop isFree
        apple.add(timed("Lossy 2", notes: "n")) // Google will rewrite notes
        try sync()
        try assertQuiet()
        try assertQuiet()
    }

    // MARK: Guards and failure handling

    func testAppleReadFailureWritesNothing() throws {
        apple.add(timed("A"))
        try sync()
        apple.failSnapshot = true
        let before = google.writes
        XCTAssertThrowsError(try sync())
        XCTAssertEqual(google.writes, before)
    }

    func testGoogleReadFailureWritesNothing() throws {
        apple.add(timed("A"))
        google.failChanges = true
        XCTAssertThrowsError(try sync())
        XCTAssertEqual(google.writes, 0)
        XCTAssertEqual(apple.writes, 0)
    }

    func testEmptyAppleSnapshotDoesNotWipeGoogle() throws {
        for i in 0..<5 { apple.add(timed("E\(i)")) }
        try sync()
        apple.events = [:]
        let report = try sync()
        XCTAssertNotNil(report.blockedReason)
        XCTAssertEqual(google.events.count, 5)
        XCTAssertFalse(report.succeeded)
        try sync(allowMassDelete: true)
        XCTAssertTrue(google.events.isEmpty)
    }

    func testLargeDropInAppleEventsIsBlocked() throws {
        config.maxDeletesPerRun = 3
        var ids: [String] = []
        for i in 0..<10 { ids.append(apple.add(timed("E\(i)")).localID) }
        try sync()
        for id in ids.prefix(5) { apple.remove(id) }
        XCTAssertNotNil(try sync().blockedReason)
        XCTAssertEqual(google.events.count, 10)
        // A drop within the limit goes through.
        config.maxDeletesPerRun = 5
        XCTAssertNil(try sync().blockedReason)
        XCTAssertEqual(google.events.count, 5)
    }

    func testMassDeletionOfAppleEventsFromGoogleIsBlocked() throws {
        config.maxAppleDeletesPerRun = 2
        for i in 0..<6 { apple.add(timed("E\(i)")) }
        try sync()
        google.wipe()
        let report = try sync()
        XCTAssertNotNil(report.blockedReason)
        XCTAssertEqual(apple.events.count, 6, "Apple originals must survive an emptied Google calendar")
        XCTAssertEqual(apple.writes, 0)
    }

    func testEmptiedGoogleCalendarIsBlockedBelowTheNormalLimit() throws {
        XCTAssertEqual(config.maxAppleDeletesPerRun, 10)
        for i in 0..<4 { apple.add(timed("E\(i)")) }
        try sync()
        google.wipe()
        XCTAssertNotNil(try sync().blockedReason)
        XCTAssertEqual(apple.events.count, 4)
    }

    func testDeletingTheOnlyEventOnEitherSideIsNotBlocked() throws {
        let a = apple.add(timed("Only one"))
        try sync()
        apple.remove(a.localID)
        XCTAssertNil(try sync().blockedReason)
        XCTAssertTrue(google.events.isEmpty)

        let g = google.userCreate(timed("Only one in Google"))
        try sync()
        google.userDelete(g.id)
        XCTAssertNil(try sync().blockedReason)
        XCTAssertTrue(apple.events.isEmpty)
    }

    func testFailedActionIsRetriedAndRunIsNotASuccess() throws {
        apple.add(timed("A"))
        google.failInserts = true
        let report = try sync()
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertNil(try store.meta(MetaKey.lastSuccess))
        google.failInserts = false
        XCTAssertTrue(try sync().succeeded)
        XCTAssertEqual(google.events.count, 1)
        XCTAssertNotNil(try store.meta(MetaKey.lastSuccess))
    }

    func testDryRunWritesNothingAnywhere() throws {
        apple.add(timed("A"))
        google.userCreate(timed("G"))
        let report = try sync(dryRun: true)
        XCTAssertEqual(report.plan.actions.count, 2)
        XCTAssertEqual(apple.writes + google.writes, 0)
        XCTAssertTrue(try store.allLinks().isEmpty)
        XCTAssertNil(try store.meta(MetaKey.googleSyncToken))
        XCTAssertTrue(try store.allGoogleEvents().isEmpty)
    }

    // MARK: Recovery

    func testExpiredSyncTokenFallsBackToFullListing() throws {
        apple.add(timed("A"))
        google.userCreate(timed("G"))
        try sync()
        google.expireTokens = true
        try assertQuiet()
        XCTAssertEqual(apple.events.count, 2)
        XCTAssertEqual(google.events.count, 2)
    }

    func testLostDatabaseAdoptsExistingCopiesInsteadOfDuplicating() throws {
        for i in 0..<4 { apple.add(timed("E\(i)")) }
        try sync()
        store = try SQLiteStateStore.inMemory()
        let before = google.writes
        let report = try sync()
        XCTAssertEqual(google.events.count, 4)
        XCTAssertEqual(google.writes, before, "identical copies are adopted without a write")
        XCTAssertEqual(report.plan.count { if case .adopt = $0 { return true }; return false }, 4)
        XCTAssertEqual(try store.allLinks().count, 4)
        try assertQuiet()
    }

    func testLostDatabaseDoesNotDuplicateEventsCreatedInGoogle() throws {
        google.userCreate(timed("From AI", notes: "n"))
        apple.add(timed("From Apple"))
        try sync()
        XCTAssertEqual(apple.events.count, 2)
        XCTAssertEqual(google.events.count, 2)
        store = try SQLiteStateStore.inMemory()
        let aw = apple.writes, gw = google.writes
        try sync()
        XCTAssertEqual(apple.events.count, 2, "the Apple copy of a Google event must be paired again, not created twice")
        XCTAssertEqual(google.events.count, 2)
        XCTAssertEqual(apple.writes, aw)
        XCTAssertEqual(google.writes, gw)
        XCTAssertEqual(try store.allLinks().filter { $0.origin == .google }.count, 1)
        try assertQuiet()
    }

    func testAmbiguousContentIsNotPaired() throws {
        // Two identical unmarked Google events and two identical Apple events: no safe pairing.
        google.userCreate(timed("Twin"))
        google.userCreate(timed("Twin"))
        try sync()
        XCTAssertEqual(apple.events.count, 2)
        try assertQuiet()
    }

    func testEventMovedToAnotherCalendarKeepsItsPairing() throws {
        let g = google.userCreate(timed("Move me"))
        try sync()
        let a = apple.events.values.first!
        // The user drags it from the target calendar into another synced calendar.
        var moved = AppleCalEvent(calendarID: "CAL", externalID: a.externalID, localID: a.localID, occurrence: nil,
                                  isRecurring: false, content: a.content, lastModified: nil)
        moved.content.title = "Move me"
        apple.events[a.localID] = moved
        let aw = apple.writes, gw = google.writes
        try sync()
        XCTAssertEqual(apple.events.count, 1)
        XCTAssertEqual(Array(google.events.keys), [g.id], "the Google event is kept, not replaced")
        XCTAssertEqual(apple.writes, aw)
        XCTAssertEqual(google.writes, gw)
        XCTAssertEqual(try store.allLinks().first?.appleKey, moved.key)
        // And it is still two-way afterwards.
        google.userEdit(g.id) { $0.title = "Moved and edited" }
        try sync()
        XCTAssertEqual(apple.events[a.localID]?.content.title, "Moved and edited")
        try assertQuiet()
    }

    func testWritesFollowAChangedLocalIdentifier() throws {
        let a = apple.add(timed("Rebuilt"))
        try sync()
        // The Calendar database was rebuilt: same event, same key, new local identifier.
        apple.events[a.localID] = nil
        var again = a
        again.localID = "L-NEW"
        apple.events["L-NEW"] = again
        google.userEdit(google.events.keys.first!) { $0.title = "Rebuilt (edited)" }
        try sync()
        XCTAssertEqual(apple.events.count, 1, "the edit must reach the existing event, not create a second one")
        XCTAssertEqual(apple.events["L-NEW"]?.content.title, "Rebuilt (edited)")
        XCTAssertEqual(try store.allLinks().first?.appleLocalID, "L-NEW")
        try assertQuiet()
    }

    func testGuardBaselineAdvancesEvenWhenAnActionFails() throws {
        config.maxDeletesPerRun = 3
        apple.add(timed("first"))
        try sync()
        google.failInserts = true
        var ids: [String] = []
        for i in 0..<10 { ids.append(apple.add(timed("E\(i)")).localID) }
        _ = try sync()
        XCTAssertEqual(try store.meta(MetaKey.prevAppleCount), "11")
        google.failInserts = false
        try sync()
        for id in ids.prefix(6) { apple.remove(id) }
        XCTAssertNotNil(try sync().blockedReason, "a drop of 6 with limit 3 must be blocked")
    }

    func testCopiesFromThePythonVersionAreAdoptedByUID() throws {
        let single = apple.add(timed("Single"))
        let occ = apple.add(timed("Series"), occurrence: "2026-06-16T10:00:00+00:00", recurring: true)
        // Keys as sync.py wrote them: sha1(calendar path)[:12] | UID [| recurrence id]
        google.events["p1"] = GoogleEvent(id: "p1", content: timed("Single"), mirrorKey: "abc123def456|\(single.externalID)")
        google.events["p2"] = GoogleEvent(id: "p2", content: timed("Series"), mirrorKey: "abc123def456|\(occ.externalID)|2026-06-16T10:00:00+00:00")
        google.events["p3"] = GoogleEvent(id: "p3", content: timed("Gone"), mirrorKey: "abc123def456|NO-SUCH-UID")
        try sync()
        XCTAssertEqual(Set(google.events.keys), ["p1", "p2"], "matched copies are kept, the orphan is removed")
        XCTAssertEqual(google.events["p1"]?.mirrorKey, single.key, "the key is rewritten to the new format")
        try assertQuiet()
    }

    func testReplacedGoogleCalendarRecopiesWithoutDeletingAppleEvents() throws {
        for i in 0..<3 { apple.add(timed("E\(i)")) }
        google.userCreate(timed("From Google"))
        try sync()
        XCTAssertEqual(apple.events.count, 4)
        // The user deleted the mirror calendar; the tool created a new, empty one.
        google = FakeGoogle()
        try SyncEngine.resetGoogleState(in: store)
        let report = try sync()
        XCTAssertNil(report.blockedReason)
        XCTAssertEqual(apple.events.count, 4)
        XCTAssertEqual(google.events.count, 4)
        try assertQuiet()
    }

    // MARK: Window

    func testEventThatScrolledOutOfTheWindowKeepsItsCopy() throws {
        let a = apple.add(timed("Past", day: -29))
        try sync()
        // Time passes: the event is now older than past_days and drops out of the snapshot.
        config.pastDays = 20
        try sync()
        XCTAssertEqual(google.events.count, 1, "history is left alone")
        XCTAssertTrue(try store.allLinks().isEmpty)
        XCTAssertNotNil(apple.events[a.localID])
        try assertQuiet()
    }

    func testSingleEventMovedBeyondTheWindowIsUpdatedNotDeleted() throws {
        let a = apple.add(timed("Trip"))
        try sync()
        apple.edit(a.localID) { $0.timing = .timed(start: day(500), end: day(501)) }
        try sync()
        XCTAssertEqual(google.events.count, 1)
        XCTAssertEqual(google.events.values.first?.content?.timing, .timed(start: day(500), end: day(501)))
        try assertQuiet()
    }

    func testGoogleEventsOutsideTheWindowAreIgnored() throws {
        google.userCreate(timed("Ancient", day: -400))
        google.userCreate(timed("Far future", day: 800))
        try sync()
        XCTAssertTrue(apple.events.isEmpty)
    }

    func testOrphanedMirrorCopyOutsideWindowIsLeftAlone() throws {
        google.events["old"] = GoogleEvent(id: "old", content: timed("Old", day: -200), mirrorKey: "CAL|GONE")
        google.events["new"] = GoogleEvent(id: "new", content: timed("New", day: 3), mirrorKey: "CAL|GONE2")
        try sync()
        XCTAssertEqual(Array(google.events.keys), ["old"])
    }
}
