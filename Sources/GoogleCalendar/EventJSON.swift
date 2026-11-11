import Foundation
import SyncCore

enum EventJSON {
    // MARK: Reading

    static func parse(_ o: [String: Any]) -> GoogleEvent? {
        guard let id = o["id"] as? String else { return nil }
        let cancelled = (o["status"] as? String) == "cancelled"
        let priv = (o["extendedProperties"] as? [String: Any])?["private"] as? [String: Any]
        let mirrorKey = (priv?["icloudSync"] as? String) == "1" ? priv?["icloudKey"] as? String : nil
        let recurring = !((o["recurrence"] as? [String])?.isEmpty ?? true) || o["recurringEventId"] is String
        return GoogleEvent(id: id, content: content(o), updated: (o["updated"] as? String).flatMap(RFC3339.parse),
                           isRecurring: recurring, mirrorKey: mirrorKey, isCancelled: cancelled)
    }

    private static func content(_ o: [String: Any]) -> EventContent? {
        guard let s = o["start"] as? [String: Any], let e = o["end"] as? [String: Any] else { return nil }
        let timing: EventTiming
        if let sd = s["dateTime"] as? String, let ed = e["dateTime"] as? String {
            guard let a = RFC3339.parse(sd), let b = RFC3339.parse(ed) else { return nil }
            timing = .timed(start: a, end: b)
        } else if let sd = s["date"] as? String, let ed = e["date"] as? String {
            timing = .allDay(startDay: sd, endDayExclusive: ed)
        } else {
            return nil
        }
        return EventContent(title: (o["summary"] as? String) ?? "", timing: timing,
                            location: o["location"] as? String, notes: o["description"] as? String,
                            isFree: (o["transparency"] as? String) == "transparent",
                            timeZoneID: s["timeZone"] as? String)
    }

    // MARK: Writing

    /// Insert and patch share this field set. Every field is always present (null where unused)
    /// so a patch fully replaces the previous value, including switching timed <-> all-day.
    static func body(_ c: EventContent, mirrorKey: String?, forInsert: Bool) -> [String: Any] {
        let null = NSNull()
        let title = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var o: [String: Any] = [
            "summary": title.isEmpty ? EventContent.untitled : title,
            "location": c.location ?? "",
            "description": c.notes ?? "",
            "transparency": c.isFree ? "transparent" : "opaque",
        ]
        switch c.timing {
        case .timed(let s, let e):
            let tz = c.timeZoneID.flatMap(TimeZone.init(identifier:))
            let zone = tz ?? TimeZone(identifier: "UTC")!
            func side(_ d: Date) -> [String: Any] {
                ["dateTime": RFC3339.format(d, in: zone), "date": null, "timeZone": tz?.identifier ?? null]
            }
            o["start"] = side(s)
            o["end"] = side(e)
        case .allDay(let s, let e):
            o["start"] = ["date": s, "dateTime": null, "timeZone": null] as [String: Any]
            o["end"] = ["date": e, "dateTime": null, "timeZone": null] as [String: Any]
        }
        if let key = mirrorKey {
            o["extendedProperties"] = ["private": ["icloudSync": "1", "icloudKey": key,
                                                   "icloudHash": c.contentHash]]
            // The Apple original already alerts; a second alert from the copy would be noise.
            if forInsert { o["reminders"] = ["useDefault": false, "overrides": [Any]()] as [String: Any] }
        }
        return o
    }
}
