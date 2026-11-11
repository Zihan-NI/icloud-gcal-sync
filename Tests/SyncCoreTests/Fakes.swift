import Foundation
import SyncCore

let utc = TimeZone(identifier: "UTC")!
/// Fixed "now" for every test: 2026-06-15 12:00 UTC.
let testNow = Date(timeIntervalSince1970: 1_781_524_800)

func day(_ offset: Int, hour: Int = 10) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.startOfDay(for: testNow).addingTimeInterval(Double(offset) * 86400 + Double(hour) * 3600)
}

func timed(_ title: String, day offset: Int = 1, hours: Double = 1, location: String? = nil, notes: String? = nil) -> EventContent {
    EventContent(title: title, timing: .timed(start: day(offset), end: day(offset).addingTimeInterval(hours * 3600)),
                 location: location, notes: notes)
}

final class FakeApple: AppleCalendarStore {
    static let targetCalendar = "TARGET"
    var events: [String: AppleCalEvent] = [:]   // by localID
    var failSnapshot = false
    var writes = 0
    private var counter = 0
    /// Simulates a calendar that cannot store free/busy: the value is dropped on save.
    var dropsFreeFlag = false

    func snapshot(window: DateInterval) throws -> [AppleCalEvent] {
        if failSnapshot { throw AppleStoreError.accessDenied("test") }
        return events.values.filter {
            let s = $0.content.timing.startInstant(in: utc)
            return s >= window.start && s < window.end
        }
    }
    func lookup(localID: String) throws -> AppleCalEvent? { events[localID] }

    private func stored(_ c: EventContent) -> EventContent {
        var c = c
        if dropsFreeFlag { c.isFree = false }
        return c
    }
    func create(_ content: EventContent) throws -> AppleCalEvent {
        writes += 1
        return add(content, calendar: FakeApple.targetCalendar)
    }
    func update(localID: String, content: EventContent) throws -> AppleCalEvent {
        guard var e = events[localID] else { throw AppleStoreError.notFound }
        writes += 1
        e.content = stored(content)
        e.lastModified = testNow
        events[localID] = e
        return e
    }
    func delete(localID: String) throws {
        writes += 1
        events[localID] = nil
    }

    // What the user does in Apple Calendar.
    @discardableResult
    func add(_ content: EventContent, calendar: String = "CAL", occurrence: String? = nil, recurring: Bool = false,
             readOnly: Bool = false, modified: Date? = nil) -> AppleCalEvent {
        counter += 1
        let e = AppleCalEvent(calendarID: calendar, externalID: "UID-\(counter)", localID: "L\(counter)", occurrence: occurrence,
                           isRecurring: recurring, content: stored(content), lastModified: modified, isReadOnly: readOnly)
        events[e.localID] = e
        return e
    }
    func edit(_ localID: String, modified: Date? = nil, _ change: (inout EventContent) -> Void) {
        change(&events[localID]!.content)
        events[localID]!.lastModified = modified
    }
    func remove(_ localID: String) { events[localID] = nil }
}

/// A Google calendar with real incremental-sync behaviour: every change gets a sequence
/// number and a sync token is "everything up to sequence N".
final class FakeGoogle: GoogleCalendarAPI {
    var events: [String: GoogleEvent] = [:]
    private var log: [(seq: Int, id: String)] = []
    private var seq = 0
    private var counter = 0
    var writes = 0
    var expireTokens = false
    var failChanges = false
    var failInserts = false
    /// Simulates the service rewriting a field on save.
    var rewrite: (EventContent) -> EventContent = { $0 }

    private func record(_ id: String) { seq += 1; log.append((seq, id)) }

    func changes(since syncToken: String?) throws -> GoogleDelta {
        if failChanges { throw GoogleAPIError.transport("test") }
        guard let syncToken else {
            return GoogleDelta(events: Array(events.values), nextSyncToken: "t\(seq)", isFull: true)
        }
        if expireTokens { expireTokens = false; throw GoogleAPIError.syncTokenExpired }
        let from = Int(syncToken.dropFirst())!
        let ids = Set(log.filter { $0.seq > from }.map(\.id))
        let changed = ids.map { events[$0] ?? GoogleEvent(id: $0, content: nil, isCancelled: true) }
        return GoogleDelta(events: changed, nextSyncToken: "t\(seq)", isFull: false)
    }
    func insert(_ content: EventContent, mirrorKey: String?) throws -> GoogleEvent {
        if failInserts { throw GoogleAPIError.http(status: 500, body: "test") }
        writes += 1
        counter += 1
        let e = GoogleEvent(id: "g\(counter)", content: rewrite(content), updated: testNow, mirrorKey: mirrorKey)
        events[e.id] = e
        record(e.id)
        return e
    }
    func patch(id: String, content: EventContent, mirrorKey: String?) throws -> GoogleEvent {
        guard var e = events[id] else { throw GoogleAPIError.notFound }
        writes += 1
        e.content = rewrite(content)
        e.updated = testNow
        if let mirrorKey { e.mirrorKey = mirrorKey }
        events[id] = e
        record(id)
        return e
    }
    func delete(id: String) throws {
        writes += 1
        if events.removeValue(forKey: id) != nil { record(id) }
    }

    // What the user (or an AI assistant) does in Google Calendar.
    @discardableResult
    func userCreate(_ content: EventContent, recurring: Bool = false, updated: Date? = nil) -> GoogleEvent {
        counter += 1
        let e = GoogleEvent(id: "g\(counter)", content: content, updated: updated, isRecurring: recurring)
        events[e.id] = e
        record(e.id)
        return e
    }
    func userEdit(_ id: String, updated: Date? = nil, _ change: (inout EventContent) -> Void) {
        var c = events[id]!.content!
        change(&c)
        events[id]!.content = c
        events[id]!.updated = updated
        record(id)
    }
    func userDelete(_ id: String) {
        events[id] = nil
        record(id)
    }
    func wipe() {
        for id in events.keys { record(id) }
        events = [:]
    }
}
