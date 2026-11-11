import Foundation
import SyncCore

public final class GoogleCalendarDirectory {
    public static let tag = "[icloud-gcal-sync]"
    private let http: GoogleHTTP

    public init(authorizer: GoogleAuthorizer, transport: HTTPTransport,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        http = GoogleHTTP(transport: transport, authorizer: authorizer, sleep: sleep)
    }

    /// Returns the id of the mirror calendar, or nil when it does not exist and `create` is false.
    public func ensureCalendar(name: String, storedID: String?, create: Bool) throws -> String? {
        if let storedID {
            let (_, status) = try http.request("GET", "/calendars/\(GoogleHTTP.pathComponent(storedID))", also: [404])
            if status != 404 { return storedID }
            Log.warning("stored Google calendar \(storedID) no longer exists; searching again")
        }
        var pageToken: String?
        repeat {
            var q: [(String, String)] = [("minAccessRole", "owner"), ("maxResults", "250")]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let (data, _) = try http.request("GET", "/users/me/calendarList", query: q)
            let o = try http.json(data)
            for item in o["items"] as? [[String: Any]] ?? [] {
                // The tag keeps us from adopting (and later wiping) a user calendar that merely shares the name.
                if item["summary"] as? String == name,
                   (item["description"] as? String)?.contains(Self.tag) == true,
                   let id = item["id"] as? String { return id }
            }
            pageToken = o["nextPageToken"] as? String
        } while pageToken != nil
        guard create else { return nil }

        let description = """
            Created and managed by icloud-gcal-sync. Events are synced two ways with Apple Calendar: \
            events created in this calendar are copied to Apple Calendar, and edits or deletions made \
            on either side are carried over to the other. \(Self.tag)
            """
        let (data, _) = try http.request("POST", "/calendars", body: [
            "summary": name, "description": description, "timeZone": TimeZone.current.identifier,
        ])
        guard let id = try http.json(data)["id"] as? String else {
            throw GoogleAPIError.malformedResponse("calendar insert response has no id")
        }
        Log.info("created Google calendar \"\(name)\"")
        return id
    }
}
