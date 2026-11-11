import XCTest
@testable import GoogleCalendar
import SyncCore

final class ClientTests: XCTestCase {
    private let content = EventContent(title: "T", timing: .allDay(startDay: "2026-03-05", endDayExclusive: "2026-03-06"))

    private func queryItems(_ r: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testFullListingPaginatesAndKeepsLastSyncToken() throws {
        let env = try Env()
        let t = FakeTransport.script([
            (200, #"{"items":[{"id":"1","summary":"a","start":{"date":"2026-03-05"},"end":{"date":"2026-03-06"}}],"nextPageToken":"P2"}"#),
            (200, #"{"items":[{"id":"2","summary":"b","start":{"date":"2026-03-05"},"end":{"date":"2026-03-06"}}],"nextSyncToken":"S1"}"#),
        ])
        let d = try env.client(t).changes(since: nil)
        XCTAssertEqual(d.events.map(\.id), ["1", "2"])
        XCTAssertEqual(d.nextSyncToken, "S1")
        XCTAssertTrue(d.isFull)
        let q0 = queryItems(t.requests[0]), q1 = queryItems(t.requests[1])
        XCTAssertEqual(q0["maxResults"], "2500"); XCTAssertEqual(q0["singleEvents"], "false")
        XCTAssertEqual(q0["showDeleted"], "false"); XCTAssertNil(q0["syncToken"]); XCTAssertNil(q0["pageToken"])
        XCTAssertEqual(q1["pageToken"], "P2")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok1")
        XCTAssertTrue(t.requests[0].url!.path.hasPrefix("/calendar/v3/calendars/cal@group.calendar.google.com/events"))
    }

    func testIncrementalListingUsesTokenAndReturnsCancelled() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"items":[{"id":"1","status":"cancelled"}],"nextSyncToken":"S2"}"#)])
        let d = try env.client(t).changes(since: "S1")
        XCTAssertFalse(d.isFull)
        XCTAssertEqual(d.nextSyncToken, "S2")
        XCTAssertTrue(d.events[0].isCancelled)
        let q = queryItems(t.requests[0])
        XCTAssertEqual(q["syncToken"], "S1"); XCTAssertNil(q["showDeleted"])
    }

    func testSyncTokenEncodedAndExpired() throws {
        let env = try Env()
        let t = FakeTransport.script([(410, #"{"error":{"code":410}}"#)])
        XCTAssertThrowsError(try env.client(t).changes(since: "a+b/c=")) {
            XCTAssertEqual($0 as? GoogleAPIError, .syncTokenExpired)
        }
        XCTAssertEqual(queryItems(t.requests[0])["syncToken"], "a+b/c=")
        XCTAssertTrue(t.requests[0].url!.absoluteString.contains("syncToken=a%2Bb%2Fc%3D"))
    }

    func testRetriesThenSucceedsWithBackoff() throws {
        let env = try Env()
        let t = FakeTransport.script([
            (503, "x"), (429, "x"),
            (403, #"{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}"#),
            (500, "x"), (200, #"{"nextSyncToken":"S"}"#),
        ])
        let d = try env.client(t).changes(since: nil)
        XCTAssertEqual(d.nextSyncToken, "S")
        XCTAssertEqual(t.requests.count, 5)
        XCTAssertEqual(env.sleeps.values.count, 4)
        XCTAssertTrue(zip(env.sleeps.values, env.sleeps.values.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testGivesUpAfterFiveAttempts() throws {
        let env = try Env()
        let t = FakeTransport { _ in (503, "down") }
        XCTAssertThrowsError(try env.client(t).changes(since: nil)) {
            XCTAssertEqual($0 as? GoogleAPIError, .http(status: 503, body: "down"))
        }
        XCTAssertEqual(t.requests.count, 5)
    }

    func testPlain403IsNotRetried() throws {
        let env = try Env()
        let t = FakeTransport.script([(403, #"{"error":{"errors":[{"reason":"forbidden"}]}}"#)])
        XCTAssertThrowsError(try env.client(t).changes(since: nil))
        XCTAssertEqual(t.requests.count, 1)
    }

    func testTransportErrorsAreRetried() throws {
        let env = try Env()
        var n = 0
        let t = FakeTransport { _ in
            n += 1
            if n < 3 { throw GoogleAPIError.transport("offline") }
            return (200, #"{"nextSyncToken":"S"}"#)
        }
        XCTAssertEqual(try env.client(t).changes(since: nil).nextSyncToken, "S")
        XCTAssertEqual(t.requests.count, 3)
    }

    func test401RefreshesOnceAndRetries() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"tok2","expires_in":3600}"#)])
        let env = try Env(authTransport: auth)
        let t = FakeTransport.script([(401, "{}"), (200, #"{"nextSyncToken":"S"}"#)])
        _ = try env.client(t).changes(since: nil)
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok1")
        XCTAssertEqual(t.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok2")
        XCTAssertEqual(auth.requests.count, 1)
        XCTAssertTrue(env.sleeps.values.isEmpty)
    }

    func testRepeated401IsUnauthorized() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"tok2","expires_in":3600}"#)])
        let env = try Env(authTransport: auth)
        let t = FakeTransport { _ in (401, "{}") }
        XCTAssertThrowsError(try env.client(t).changes(since: nil)) {
            guard case .unauthorized? = $0 as? GoogleAPIError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testInsertBody() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"id":"new1","summary":"T","start":{"date":"2026-03-05"},"end":{"date":"2026-03-06"}}"#)])
        let e = try env.client(t).insert(content, mirrorKey: "K")
        XCTAssertEqual(e.id, "new1")
        XCTAssertEqual(t.requests[0].httpMethod, "POST")
        let b = t.bodyJSON(0)
        XCTAssertNotNil(b["reminders"])
        XCTAssertEqual(((b["extendedProperties"] as! [String: Any])["private"] as! [String: String])["icloudHash"], content.contentHash)
    }

    func testPatchBodyClearsOtherRepresentation() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"id":"e/1"}"#)])
        _ = try env.client(t).patch(id: "e/1", content: content, mirrorKey: nil)
        XCTAssertEqual(t.requests[0].httpMethod, "PATCH")
        XCTAssertTrue(t.requests[0].url!.absoluteString.hasSuffix("/events/e%2F1"))
        let b = t.bodyJSON(0)
        XCTAssertTrue((b["start"] as! [String: Any])["dateTime"] is NSNull)
        XCTAssertNil(b["extendedProperties"]); XCTAssertNil(b["reminders"])
        XCTAssertEqual(b["location"] as? String, "")
    }

    func testDeleteTreatsGoneAsSuccess() throws {
        let env = try Env()
        for status in [204, 404, 410] {
            let t = FakeTransport.script([(status, "")])
            XCTAssertNoThrow(try env.client(t).delete(id: "x"))
            XCTAssertEqual(t.requests[0].httpMethod, "DELETE")
        }
        let t = FakeTransport.script([(400, "bad")])
        XCTAssertThrowsError(try env.client(t).delete(id: "x"))
    }

    func testPatchOfDeletedEventThrowsNotFound() throws {
        let env = try Env()
        for status in [404, 410] {
            let t = FakeTransport.script([(status, "{}")])
            XCTAssertThrowsError(try env.client(t).patch(id: "x", content: content, mirrorKey: nil)) {
                XCTAssertEqual($0 as? GoogleAPIError, .notFound)
            }
        }
    }

    func testListingWithoutSyncTokenIsAnError() throws {
        let env = try Env()
        let t = FakeTransport.script([(200, #"{"items":[]}"#)])
        XCTAssertThrowsError(try env.client(t).changes(since: nil))
    }
}
