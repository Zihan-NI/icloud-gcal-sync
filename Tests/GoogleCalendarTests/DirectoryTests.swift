import XCTest
@testable import GoogleCalendar
import SyncCore

final class DirectoryTests: XCTestCase {
    func testStoredIDStillExists() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"id":"stored"}"#)])
        XCTAssertEqual(try env.directory(t).ensureCalendar(name: "N", storedID: "stored", create: true), "stored")
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].httpMethod, "GET")
    }

    func testStoredGoneFindsTaggedCalendarAcrossPages() throws {
        let env = try Env()
        let t = FakeTransport.script([
            (404, "{}"),
            (200, #"{"items":[{"id":"u","summary":"N","description":"mine"}],"nextPageToken":"p2"}"#),
            (200, #"{"items":[{"id":"t","summary":"N","description":"x [icloud-gcal-sync]"}]}"#),
        ])
        XCTAssertEqual(try env.directory(t).ensureCalendar(name: "N", storedID: "gone", create: true), "t")
        let url = t.requests[1].url!.absoluteString
        XCTAssertTrue(url.contains("minAccessRole=owner"))
        XCTAssertTrue(t.requests[2].url!.absoluteString.contains("pageToken=p2"))
    }

    func testRefusesUntaggedSameNameAndCreates() throws {
        let env = try Env()
        let t = FakeTransport.script([
            (200, #"{"items":[{"id":"u","summary":"N"},{"id":"v","summary":"N","description":"nope"}]}"#),
            (200, #"{"id":"created"}"#),
        ])
        XCTAssertEqual(try env.directory(t).ensureCalendar(name: "N", storedID: nil, create: true), "created")
        XCTAssertEqual(t.requests[1].httpMethod, "POST")
        let b = t.bodyJSON(1)
        XCTAssertEqual(b["summary"] as? String, "N")
        XCTAssertEqual(b["timeZone"] as? String, TimeZone.current.identifier)
        let d = b["description"] as! String
        XCTAssertTrue(d.hasSuffix("[icloud-gcal-sync]"))
        XCTAssertTrue(d.contains("copied to Apple Calendar"))
    }

    func testNoCreateReturnsNil() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"items":[{"id":"u","summary":"N"}]}"#)])
        XCTAssertNil(try env.directory(t).ensureCalendar(name: "N", storedID: nil, create: false))
        XCTAssertEqual(t.requests.count, 1)
    }
}
