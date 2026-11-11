import Foundation

// All three protocols are synchronous and are only ever called from the engine's serial queue.

/// The Apple calendars this tool reads and writes. Implemented with EventKit.
public protocol AppleCalendarStore: AnyObject {
    /// Every occurrence starting inside `window` in the synced calendars (the configured
    /// iCloud calendars plus the write-back target calendar). Recurring events are expanded.
    func snapshot(window: DateInterval) throws -> [AppleCalEvent]
    /// Direct lookup of a single (non-recurring) event that may lie outside the window.
    /// Returns nil when the event no longer exists.
    func lookup(localID: String) throws -> AppleCalEvent?
    /// Create a single event in the write-back target calendar.
    func create(_ content: EventContent) throws -> AppleCalEvent
    /// Overwrite the synced fields of a single event. Returns the event as stored afterwards.
    func update(localID: String, content: EventContent) throws -> AppleCalEvent
    /// Delete a single event. Deleting something already gone is not an error.
    func delete(localID: String) throws
}

/// One Google calendar (the dedicated mirror calendar). Implemented over the REST API.
public protocol GoogleCalendarAPI: AnyObject {
    /// Changes since `syncToken`, or the whole calendar when it is nil.
    /// Throws `GoogleAPIError.syncTokenExpired` when Google answers 410; the caller then
    /// retries with nil.
    func changes(since syncToken: String?) throws -> GoogleDelta
    /// `mirrorKey` non-nil marks the event as a copy of an Apple event (sets the private
    /// extended properties and disables reminders). nil leaves the event unmarked.
    func insert(_ content: EventContent, mirrorKey: String?) throws -> GoogleEvent
    /// Patch only the synced fields; everything else on the event (attendees, colour,
    /// reminders of a Google-created event…) is preserved.
    func patch(id: String, content: EventContent, mirrorKey: String?) throws -> GoogleEvent
    /// Deleting something already gone (404/410) is not an error.
    func delete(id: String) throws
}

public enum GoogleAPIError: Error, Equatable, CustomStringConvertible {
    case syncTokenExpired
    case notFound
    /// Refresh token rejected or missing: the user has to run `auth` again.
    case unauthorized(String)
    case http(status: Int, body: String)
    case transport(String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .syncTokenExpired: return "Google sync token expired"
        case .notFound: return "Google resource not found"
        case .unauthorized(let m): return "Google authorization failed: \(m)"
        case .http(let status, let body): return "Google API HTTP \(status): \(body.prefix(300))"
        case .transport(let m): return "Google API network error: \(m)"
        case .malformedResponse(let m): return "Google API malformed response: \(m)"
        }
    }
}

/// Local persistent state. Implemented with SQLite.
public protocol SyncStateStore: AnyObject {
    func meta(_ key: String) throws -> String?
    /// nil removes the key.
    func setMeta(_ key: String, _ value: String?) throws

    func allLinks() throws -> [Link]
    /// Returns the link with its new `id`.
    func insertLink(_ link: Link) throws -> Link
    func updateLink(_ link: Link) throws
    func deleteLink(id: Int64) throws

    /// The local mirror of the Google calendar's current contents.
    func allGoogleEvents() throws -> [GoogleEvent]
    func upsertGoogleEvent(_ event: GoogleEvent) throws
    func deleteGoogleEvent(id: String) throws
    /// Replace the whole cache (after a full listing).
    func replaceGoogleEvents(_ events: [GoogleEvent]) throws

    /// Runs `body` atomically: everything it writes is committed together, or rolled back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T
}

public enum MetaKey {
    public static let googleCalendarID = "google_calendar_id"
    public static let googleSyncToken = "google_sync_token"
    public static let appleTargetCalendarID = "apple_target_calendar_id"
    /// Number of Apple occurrences seen by the last successful run (mass-delete guard).
    public static let prevAppleCount = "prev_apple_count"
    public static let lastSuccess = "last_success"
    public static let lastAlert = "last_alert"
}
