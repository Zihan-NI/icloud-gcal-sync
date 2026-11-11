import CryptoKit
import Foundation

// MARK: - Event content

/// When an event happens. All-day events are calendar dates, not instants, so they are
/// kept as `yyyy-MM-dd` strings and never converted through a time zone.
public enum EventTiming: Equatable, Sendable, Codable {
    case timed(start: Date, end: Date)
    /// `endDayExclusive` follows Google's convention: a one-day event on the 5th is ("…-05", "…-06").
    case allDay(startDay: String, endDayExclusive: String)

    /// Instant used for window checks. All-day dates map to local midnight.
    public func startInstant(in timeZone: TimeZone = .current) -> Date {
        switch self {
        case .timed(let start, _): return start
        case .allDay(let startDay, _): return DayString.date(from: startDay, in: timeZone) ?? .distantPast
        }
    }
}

/// The fields that are synced between the two sides. Anything not listed here is left alone.
public struct EventContent: Equatable, Sendable, Codable {
    public var title: String
    public var timing: EventTiming
    public var location: String?
    public var notes: String?
    /// true = does not block time ("free" in Apple Calendar, "transparent" in Google).
    public var isFree: Bool
    /// IANA zone the event was created in. Carried across so the copy displays the same,
    /// but not part of the hash: the instants are what matter.
    public var timeZoneID: String?

    public init(title: String, timing: EventTiming, location: String? = nil, notes: String? = nil,
                isFree: Bool = false, timeZoneID: String? = nil) {
        self.title = title
        self.timing = timing
        self.location = location
        self.notes = notes
        self.isFree = isFree
        self.timeZoneID = timeZoneID
    }

    /// Canonical form used for hashing and comparison, so cosmetic differences between the
    /// two services (trailing whitespace, CRLF, empty string vs missing) do not count as edits.
    public var normalized: EventContent {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var timing = self.timing
        if case .timed(let s, let e) = timing {
            // Sub-second precision does not survive either API.
            timing = .timed(start: Date(timeIntervalSince1970: s.timeIntervalSince1970.rounded(.down)),
                            end: Date(timeIntervalSince1970: e.timeIntervalSince1970.rounded(.down)))
        }
        return EventContent(title: clean(title) ?? EventContent.untitled, timing: timing,
                            location: clean(location), notes: clean(notes), isFree: isFree, timeZoneID: nil)
    }

    public static let untitled = "(No title)"

    /// 32 hex characters of SHA-256 over the canonical form.
    public var contentHash: String {
        let n = normalized
        var parts: [String] = ["v1", n.title]
        switch n.timing {
        case .timed(let s, let e):
            parts += ["timed", String(Int64(s.timeIntervalSince1970)), String(Int64(e.timeIntervalSince1970))]
        case .allDay(let s, let e):
            parts += ["allday", s, e]
        }
        parts += [n.location ?? "", n.notes ?? "", n.isFree ? "free" : "busy"]
        // Length-prefix every field so no choice of field contents can collide with another split.
        let joined = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

/// `yyyy-MM-dd` helpers that never touch the user's locale.
public enum DayString {
    public static func string(from date: Date, in timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(from day: String, in timeZone: TimeZone = .current) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func adding(days: Int, to day: String) -> String? {
        let utc = TimeZone(identifier: "UTC")!
        guard let d = date(from: day, in: utc) else { return nil }
        return string(from: d.addingTimeInterval(Double(days) * 86400), in: utc)
    }
}

// MARK: - Apple side

/// One event occurrence as read from EventKit. Recurring events arrive already expanded.
/// (Not called `AppleEvent`: CoreServices already has a type of that name.)
public struct AppleCalEvent: Equatable, Sendable {
    /// `calendarID|externalID` for a single event, `calendarID|externalID|occurrence` for an
    /// occurrence of a recurring series.
    public var key: String
    public var calendarID: String
    /// `calendarItemExternalIdentifier`: the iCalendar UID on CalDAV accounts.
    public var externalID: String
    /// `calendarItemIdentifier`: only valid on this Mac.
    public var localID: String
    /// nil for a single event. For an occurrence: the original occurrence date, as a UTC
    /// timestamp `yyyy-MM-ddTHH:mm:ss+00:00`, or `yyyy-MM-dd` for all-day series.
    public var occurrence: String?
    /// Part of a recurring series (master rule or detached occurrence).
    public var isRecurring: Bool
    public var content: EventContent
    public var lastModified: Date?
    /// The calendar does not accept changes (e.g. a calendar shared read-only).
    public var isReadOnly: Bool

    /// Only a single event in a writable calendar can take edits and deletions from Google.
    public var syncsBothWays: Bool { !isRecurring && !isReadOnly }

    public init(calendarID: String, externalID: String, localID: String, occurrence: String?,
                isRecurring: Bool, content: EventContent, lastModified: Date?, isReadOnly: Bool = false) {
        self.isReadOnly = isReadOnly
        self.calendarID = calendarID
        self.externalID = externalID
        self.localID = localID
        self.occurrence = occurrence
        self.isRecurring = isRecurring
        self.content = content
        self.lastModified = lastModified
        self.key = AppleCalEvent.makeKey(calendarID: calendarID, externalID: externalID, occurrence: occurrence)
    }

    public static func makeKey(calendarID: String, externalID: String, occurrence: String?) -> String {
        if let occurrence { return "\(calendarID)|\(externalID)|\(occurrence)" }
        return "\(calendarID)|\(externalID)"
    }
}

// MARK: - Google side

public struct GoogleEvent: Equatable, Sendable, Codable {
    public var id: String
    /// nil when the event has no usable start/end (should not happen for live events).
    public var content: EventContent?
    public var updated: Date?
    /// A recurring master (`recurrence`) or an exception of one (`recurringEventId`).
    public var isRecurring: Bool
    /// `extendedProperties.private.icloudKey`, present only on copies this tool created
    /// (those also carry `icloudSync=1`). nil means the event was created in Google.
    public var mirrorKey: String?
    /// Only ever true inside a `GoogleDelta`: the event was deleted.
    public var isCancelled: Bool

    public init(id: String, content: EventContent?, updated: Date? = nil, isRecurring: Bool = false,
                mirrorKey: String? = nil, isCancelled: Bool = false) {
        self.id = id
        self.content = content
        self.updated = updated
        self.isRecurring = isRecurring
        self.mirrorKey = mirrorKey
        self.isCancelled = isCancelled
    }
}

/// Result of one `events.list` pass (all pages).
public struct GoogleDelta: Equatable, Sendable {
    /// Changed events. On an incremental pass deleted events appear with `isCancelled == true`.
    public var events: [GoogleEvent]
    /// Token to pass next time. Always present after a complete pass.
    public var nextSyncToken: String?
    /// true when this was a full listing (no token, or the token had expired): `events` is then
    /// the complete calendar and replaces the local cache.
    public var isFull: Bool

    public init(events: [GoogleEvent], nextSyncToken: String?, isFull: Bool) {
        self.events = events
        self.nextSyncToken = nextSyncToken
        self.isFull = isFull
    }
}

// MARK: - Links

/// Pairs one Apple event (or occurrence) with one Google event and remembers what each side
/// looked like when they were last in agreement.
public struct Link: Equatable, Sendable {
    public enum Origin: String, Sendable, Codable { case apple, google }
    public enum Mode: String, Sendable, Codable {
        /// Edits and deletions flow both ways. Single events only.
        case twoWay = "two_way"
        /// Apple is the source of truth; the Google copy is a mirror. Recurring occurrences.
        case oneWay = "one_way"
    }

    public var id: Int64?
    public var origin: Origin
    public var mode: Mode
    public var appleKey: String
    public var appleCalendarID: String
    public var appleExternalID: String
    public var appleLocalID: String
    public var occurrence: String?
    public var googleEventID: String
    /// Hash of the Apple content when the two sides last agreed. A different hash now means
    /// the user edited the event in Apple Calendar; the same hash means any change
    /// notification was our own echo.
    public var appleHash: String
    /// Same, for the Google copy as Google returned it.
    public var googleHash: String
    /// Start of the event at last sync, seconds since 1970. Used for window checks when one
    /// side has disappeared.
    public var startTS: Double
    public var lastSyncedAt: Date

    public init(id: Int64? = nil, origin: Origin, mode: Mode, appleKey: String, appleCalendarID: String,
                appleExternalID: String, appleLocalID: String, occurrence: String?, googleEventID: String,
                appleHash: String, googleHash: String, startTS: Double, lastSyncedAt: Date) {
        self.id = id
        self.origin = origin
        self.mode = mode
        self.appleKey = appleKey
        self.appleCalendarID = appleCalendarID
        self.appleExternalID = appleExternalID
        self.appleLocalID = appleLocalID
        self.occurrence = occurrence
        self.googleEventID = googleEventID
        self.appleHash = appleHash
        self.googleHash = googleHash
        self.startTS = startTS
        self.lastSyncedAt = lastSyncedAt
    }
}
