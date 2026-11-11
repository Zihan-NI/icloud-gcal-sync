import XCTest
@testable import GoogleCalendar
import SyncCore

final class EventJSONTests: XCTestCase {
    private func parse(_ json: String) -> GoogleEvent {
        let o = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return EventJSON.parse(o)!
    }

    func testTimedWithFractionAndOffset() {
        let e = parse("""
        {"id":"a","summary":"Lunch","location":"Cafe","description":"d","transparency":"transparent",
         "updated":"2026-03-01T10:00:00.123Z",
         "start":{"dateTime":"2026-03-05T12:00:00.500-05:00","timeZone":"America/New_York"},
         "end":{"dateTime":"2026-03-05T13:00:00-05:00"}}
        """)
        guard case .timed(let s, let en)? = e.content?.timing else { return XCTFail() }
        XCTAssertEqual(s.timeIntervalSince1970, date("2026-03-05T17:00:00Z").timeIntervalSince1970 + 0.5, accuracy: 0.001)
        XCTAssertEqual(en, date("2026-03-05T18:00:00Z"))
        XCTAssertEqual(e.content?.timeZoneID, "America/New_York")
        XCTAssertEqual(e.content?.title, "Lunch")
        XCTAssertTrue(e.content!.isFree)
        XCTAssertEqual(e.updated!.timeIntervalSince1970, date("2026-03-01T10:00:00Z").timeIntervalSince1970 + 0.123, accuracy: 0.001)
        XCTAssertFalse(e.isRecurring); XCTAssertNil(e.mirrorKey); XCTAssertFalse(e.isCancelled)
    }

    func testAllDayAndMissingSummary() {
        let e = parse(#"{"id":"b","start":{"date":"2026-03-05"},"end":{"date":"2026-03-06"}}"#)
        XCTAssertEqual(e.content?.timing, .allDay(startDay: "2026-03-05", endDayExclusive: "2026-03-06"))
        XCTAssertEqual(e.content?.title, "")
        XCTAssertFalse(e.content!.isFree)
        XCTAssertNil(e.content?.timeZoneID)
    }

    func testCancelledWithoutContent() {
        let e = parse(#"{"id":"c","status":"cancelled"}"#)
        XCTAssertTrue(e.isCancelled)
        XCTAssertNil(e.content)
    }

    func testRecurringDetection() {
        XCTAssertTrue(parse(#"{"id":"r","recurrence":["RRULE:FREQ=DAILY"]}"#).isRecurring)
        XCTAssertTrue(parse(#"{"id":"r","recurringEventId":"m"}"#).isRecurring)
        XCTAssertFalse(parse(#"{"id":"r","recurrence":[]}"#).isRecurring)
    }

    func testMirrorKeyRequiresMarker() {
        XCTAssertEqual(parse(#"{"id":"m","extendedProperties":{"private":{"icloudSync":"1","icloudKey":"K"}}}"#).mirrorKey, "K")
        XCTAssertNil(parse(#"{"id":"m","extendedProperties":{"private":{"icloudKey":"K"}}}"#).mirrorKey)
        XCTAssertNil(parse(#"{"id":"m","extendedProperties":{"private":{"icloudSync":"0","icloudKey":"K"}}}"#).mirrorKey)
    }

    func testBodyTimedWithZoneAndMirror() {
        let c = EventContent(title: "  Hi ", timing: .timed(start: date("2026-03-05T17:00:00Z"), end: date("2026-03-05T18:00:00Z")),
                             location: nil, notes: "n", isFree: true, timeZoneID: "America/New_York")
        let b = EventJSON.body(c, mirrorKey: "K", forInsert: true)
        XCTAssertEqual(b["summary"] as? String, "Hi")
        XCTAssertEqual(b["location"] as? String, "")
        XCTAssertEqual(b["description"] as? String, "n")
        XCTAssertEqual(b["transparency"] as? String, "transparent")
        let s = b["start"] as! [String: Any]
        XCTAssertEqual(s["dateTime"] as? String, "2026-03-05T12:00:00-05:00")
        XCTAssertEqual(s["timeZone"] as? String, "America/New_York")
        XCTAssertTrue(s["date"] is NSNull)
        let p = (b["extendedProperties"] as! [String: Any])["private"] as! [String: String]
        XCTAssertEqual(p, ["icloudSync": "1", "icloudKey": "K", "icloudHash": c.contentHash])
        let r = b["reminders"] as! [String: Any]
        XCTAssertEqual(r["useDefault"] as? Bool, false)
        XCTAssertEqual((r["overrides"] as? [Any])?.count, 0)
    }

    func testBodyAllDayClearsTimedAndPatchOmitsReminders() {
        let c = EventContent(title: "", timing: .allDay(startDay: "2026-03-05", endDayExclusive: "2026-03-06"))
        let b = EventJSON.body(c, mirrorKey: "K", forInsert: false)
        XCTAssertEqual(b["summary"] as? String, "(No title)")
        let s = b["start"] as! [String: Any]
        XCTAssertEqual(s["date"] as? String, "2026-03-05")
        XCTAssertTrue(s["dateTime"] is NSNull)
        XCTAssertTrue(s["timeZone"] is NSNull)
        XCTAssertNil(b["reminders"])
        XCTAssertNotNil(b["extendedProperties"])
    }

    func testBodyUnmarkedAndUTCFallback() {
        let c = EventContent(title: "x", timing: .timed(start: date("2026-03-05T17:00:00Z"), end: date("2026-03-05T18:00:00Z")))
        let b = EventJSON.body(c, mirrorKey: nil, forInsert: true)
        XCTAssertNil(b["extendedProperties"]); XCTAssertNil(b["reminders"])
        let s = b["start"] as! [String: Any]
        XCTAssertEqual(s["dateTime"] as? String, "2026-03-05T17:00:00Z")
        XCTAssertTrue(s["timeZone"] is NSNull)
        XCTAssertEqual(b["transparency"] as? String, "opaque")
    }
}
