import Foundation
import SyncCore

public final class GoogleCalendarClient: GoogleCalendarAPI {
    private let calendarID: String
    private let http: GoogleHTTP

    public init(calendarID: String, authorizer: GoogleAuthorizer, transport: HTTPTransport,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.calendarID = calendarID
        self.http = GoogleHTTP(transport: transport, authorizer: authorizer, sleep: sleep)
    }

    private var eventsPath: String { "/calendars/\(GoogleHTTP.pathComponent(calendarID))/events" }

    public func changes(since syncToken: String?) throws -> GoogleDelta {
        var events: [GoogleEvent] = []
        var pageToken: String?
        var next: String?
        repeat {
            var q: [(String, String)] = [("maxResults", "2500"), ("singleEvents", "false")]
            if let syncToken { q.append(("syncToken", syncToken)) } else { q.append(("showDeleted", "false")) }
            if let pageToken { q.append(("pageToken", pageToken)) }
            let (data, status) = try http.request("GET", eventsPath, query: q, also: [410])
            if status == 410 { throw GoogleAPIError.syncTokenExpired }
            let o = try http.json(data)
            events += (o["items"] as? [[String: Any]] ?? []).compactMap(EventJSON.parse)
            pageToken = o["nextPageToken"] as? String
            next = o["nextSyncToken"] as? String ?? next
        } while pageToken != nil
        // The protocol promises a token after a complete pass; without one the next run could not be incremental.
        guard let next else { throw GoogleAPIError.malformedResponse("events.list returned no nextSyncToken") }
        return GoogleDelta(events: events, nextSyncToken: next, isFull: syncToken == nil)
    }

    public func insert(_ content: EventContent, mirrorKey: String?) throws -> GoogleEvent {
        let (data, _) = try http.request("POST", eventsPath,
                                         body: EventJSON.body(content, mirrorKey: mirrorKey, forInsert: true))
        return try event(from: data)
    }

    public func patch(id: String, content: EventContent, mirrorKey: String?) throws -> GoogleEvent {
        let (data, status) = try http.request("PATCH", eventsPath + "/" + GoogleHTTP.pathComponent(id),
                                              body: EventJSON.body(content, mirrorKey: mirrorKey, forInsert: false),
                                              also: [404, 410])
        // The event was deleted in Google since the last sync; the engine decides what that means.
        if status == 404 || status == 410 { throw GoogleAPIError.notFound }
        return try event(from: data)
    }

    public func delete(id: String) throws {
        _ = try http.request("DELETE", eventsPath + "/" + GoogleHTTP.pathComponent(id), also: [404, 410])
    }

    private func event(from data: Data) throws -> GoogleEvent {
        guard let e = EventJSON.parse(try http.json(data)) else {
            throw GoogleAPIError.malformedResponse("event response has no id")
        }
        return e
    }
}
