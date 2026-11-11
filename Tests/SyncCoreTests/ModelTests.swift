import SyncCore
import XCTest

final class ModelTests: XCTestCase {
    func testHashIgnoresCosmeticDifferences() {
        let a = EventContent(title: "Lunch ", timing: .timed(start: day(1), end: day(1).addingTimeInterval(3600)),
                             location: "", notes: "line1\r\nline2\n", timeZoneID: "America/New_York")
        let b = EventContent(title: "Lunch", timing: .timed(start: day(1).addingTimeInterval(0.4), end: day(1).addingTimeInterval(3600.9)),
                             location: nil, notes: "line1\nline2", timeZoneID: nil)
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testHashSeesEveryRealField() {
        let base = timed("T", location: "L", notes: "N")
        var variants: [EventContent] = []
        var v = base; v.title = "T2"; variants.append(v)
        v = base; v.location = "L2"; variants.append(v)
        v = base; v.notes = "N2"; variants.append(v)
        v = base; v.isFree = true; variants.append(v)
        v = base; v.timing = .timed(start: day(1), end: day(1).addingTimeInterval(7200)); variants.append(v)
        v = base; v.timing = .allDay(startDay: "2026-06-16", endDayExclusive: "2026-06-17"); variants.append(v)
        let hashes = Set(variants.map(\.contentHash) + [base.contentHash])
        XCTAssertEqual(hashes.count, variants.count + 1)
    }

    func testFieldBoundariesCannotBeForged() {
        let a = EventContent(title: "x", timing: .allDay(startDay: "2026-01-01", endDayExclusive: "2026-01-02"), location: "a|b", notes: "c")
        let b = EventContent(title: "x", timing: .allDay(startDay: "2026-01-01", endDayExclusive: "2026-01-02"), location: "a", notes: "b|c")
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    func testEmptyTitleHashesLikeUntitled() {
        XCTAssertEqual(timed("").contentHash, timed(EventContent.untitled).contentHash)
    }

    func testDayStringArithmetic() {
        XCTAssertEqual(DayString.adding(days: 1, to: "2026-02-28"), "2026-03-01")
        XCTAssertEqual(DayString.adding(days: 1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(DayString.adding(days: -1, to: "2026-01-01"), "2025-12-31")
        let ny = TimeZone(identifier: "America/New_York")!
        let d = DayString.date(from: "2026-03-08", in: ny)!   // DST starts this day
        XCTAssertEqual(DayString.string(from: d, in: ny), "2026-03-08")
    }

    func testKeyFormat() {
        XCTAssertEqual(AppleCalEvent.makeKey(calendarID: "C", externalID: "U", occurrence: nil), "C|U")
        XCTAssertEqual(AppleCalEvent.makeKey(calendarID: "C", externalID: "U", occurrence: "2026-01-05"), "C|U|2026-01-05")
    }

    func testConfigReadsPythonEraFileAndDefaults() throws {
        let json = #"{"icloud_username":"you@example.com","icloud_calendars":["Home"],"google_calendar_name":"Mirror","past_days":7,"future_days":90,"max_deletes_per_run":5}"#
        let c = try JSONDecoder().decode(SyncConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.icloudCalendars, ["Home"])
        XCTAssertEqual(c.googleCalendarName, "Mirror")
        XCTAssertEqual(c.pastDays, 7)
        XCTAssertEqual(c.maxDeletesPerRun, 5)
        XCTAssertEqual(c.appleTargetCalendar, "From Google")
        XCTAssertEqual(c.conflictPolicy, .newest)
    }

    func testWindowIsWholeDaysAroundToday() {
        var c = SyncConfig()
        c.pastDays = 1; c.futureDays = 2
        let w = c.window(now: testNow, timeZone: utc)
        XCTAssertEqual(w.start, day(-1, hour: 0))
        XCTAssertEqual(w.end, day(2, hour: 0))
    }
}
