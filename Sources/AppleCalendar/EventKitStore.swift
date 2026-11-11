import EventKit
import Foundation
import SyncCore

/// The Apple side, through EventKit.
///
/// Only calendars of one account (by default "iCloud") are ever read or written. That is a
/// hard requirement, not a preference: when the user has also added their Google account
/// to Apple Calendar, EventKit shows the Google mirror calendar too, and syncing that back
/// would loop forever.
public final class EventKitStore: AppleCalendarStore {
    private let store = EKEventStore()
    private let config: SyncConfig
    /// Zone used to turn EventKit's floating all-day dates into calendar days. Set again
    /// before each cycle by a long-running process, because the Mac's zone can change.
    public var timeZone: TimeZone
    private var syncedCalendars: [EKCalendar] = []
    private var target: EKCalendar?
    private var observer: NSObjectProtocol?

    public init(config: SyncConfig, timeZone: TimeZone = .current) {
        self.config = config
        self.timeZone = timeZone
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Access

    public enum Access: String { case granted, notDetermined, denied }

    public static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Ask for full calendar access. macOS shows its prompt once; the answer is remembered
    /// against this binary's code signature. Returns the resulting state.
    public func requestAccess(timeout: TimeInterval = 300) -> Access {
        if EventKitStore.access != .notDetermined { return EventKitStore.access }
        let done = DispatchSemaphore(value: 0)
        store.requestFullAccessToEvents { _, error in
            if let error { Log.warning("calendar access request failed: \(error.localizedDescription)") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return EventKitStore.access
    }

    // MARK: - Calendars

    public struct CalendarInfo {
        public let source: String
        public let title: String
        public let identifier: String
        public let writable: Bool
        public let synced: Bool
        public let isTarget: Bool
    }

    /// Work out which calendars are synced and where events from Google go.
    /// - Parameters:
    ///   - storedTargetID: identifier of the target calendar from a previous run, so renaming
    ///     it in Apple Calendar does not create a second one.
    ///   - createTarget: create the target calendar when it does not exist.
    /// - Returns: the target calendar's identifier, or nil when it does not exist and was not created.
    @discardableResult
    public func resolveCalendars(storedTargetID: String?, createTarget: Bool) throws -> String? {
        guard EventKitStore.access == .granted else {
            throw AppleStoreError.accessDenied("calendar access is \(EventKitStore.access.rawValue)")
        }
        store.refreshSourcesIfNecessary()
        let matching = store.sources.filter { $0.title == config.appleSource }
        guard let source = matching.first(where: { $0.sourceType == .calDAV }) ?? matching.first else {
            let known = store.sources.map(\.title).sorted().joined(separator: ", ")
            throw AppleStoreError.configuration("no account named \"\(config.appleSource)\" in Apple Calendar (found: \(known))")
        }
        let all = Array(source.calendars(for: .event))
        // Right after login the account can be present before its calendars have loaded.
        // Carrying on would create a second target calendar and make every event look deleted.
        guard !all.isEmpty else {
            throw AppleStoreError.configuration("no calendars visible in \(source.title) yet; will retry")
        }

        var target = storedTargetID.flatMap { id in all.first { $0.calendarIdentifier == id } }
            ?? all.first { $0.title == config.appleTargetCalendar && $0.allowsContentModifications }
        if target == nil && createTarget {
            let cal = EKCalendar(for: .event, eventStore: store)
            cal.title = config.appleTargetCalendar
            cal.source = source
            try store.saveCalendar(cal, commit: true)
            Log.info("created Apple calendar \"\(cal.title)\" in \(source.title)")
            target = cal
        }
        self.target = target

        var synced: [EKCalendar]
        if config.icloudCalendars.isEmpty {
            synced = all
        } else {
            let wanted = Set(config.icloudCalendars)
            synced = all.filter { wanted.contains($0.title) }
            let missing = wanted.subtracting(synced.map(\.title))
            if !missing.isEmpty {
                // A hard failure: carrying on would delete every copy of that calendar's events.
                throw AppleStoreError.configuration("configured calendars not found in \(source.title): \(missing.sorted())")
            }
        }
        // A calendar named like the Google mirror would be the mirror itself seen through
        // another account; never sync it, whatever account it shows up under.
        synced.removeAll { $0.title == config.googleCalendarName }
        if let target, !synced.contains(where: { $0.calendarIdentifier == target.calendarIdentifier }) {
            synced.append(target)
        }
        self.syncedCalendars = synced
        return target?.calendarIdentifier
    }

    public func describeCalendars() -> [CalendarInfo] {
        let syncedIDs = Set(syncedCalendars.map(\.calendarIdentifier))
        return store.calendars(for: .event).map {
            CalendarInfo(source: $0.source.title, title: $0.title, identifier: $0.calendarIdentifier,
                         writable: $0.allowsContentModifications, synced: syncedIDs.contains($0.calendarIdentifier),
                         isTarget: $0.calendarIdentifier == target?.calendarIdentifier)
        }
    }

    /// Call `handler` (on the main queue) whenever anything in the calendar database changes.
    /// The notification does not say what changed, and one save produces several of them,
    /// so the caller debounces and re-reads.
    public func observeChanges(_ handler: @escaping () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            handler()
        }
    }

    // MARK: - AppleCalendarStore

    public func snapshot(window: DateInterval) throws -> [AppleCalEvent] {
        guard EventKitStore.access == .granted else {
            throw AppleStoreError.accessDenied("calendar access is \(EventKitStore.access.rawValue)")
        }
        guard !syncedCalendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: syncedCalendars)
        var out: [AppleCalEvent] = []
        var seen = Set<String>()
        for ev in store.events(matching: predicate) {
            // The predicate also returns events that merely overlap the window.
            guard ev.startDate >= window.start && ev.startDate < window.end else { continue }
            guard ev.status != .canceled, let a = appleEvent(from: ev) else { continue }
            if !seen.insert(a.key).inserted {
                Log.warning("duplicate Apple event key \(a.key); keeping the first")
                continue
            }
            out.append(a)
        }
        return out
    }

    public func lookup(localID: String) throws -> AppleCalEvent? {
        guard let ev = store.calendarItem(withIdentifier: localID) as? EKEvent else { return nil }
        guard isSynced(ev) else { return nil }
        return appleEvent(from: ev)
    }

    private func isSynced(_ ev: EKEvent) -> Bool {
        syncedCalendars.contains { $0.calendarIdentifier == ev.calendar.calendarIdentifier }
    }

    public func create(_ content: EventContent) throws -> AppleCalEvent {
        guard let target else {
            throw AppleStoreError.configuration("no Apple calendar to put events from Google in (\"\(config.appleTargetCalendar)\")")
        }
        let ev = EKEvent(eventStore: store)
        ev.calendar = target
        apply(content, to: ev)
        try store.save(ev, span: .thisEvent, commit: true)
        guard let a = appleEvent(from: ev) else {
            throw AppleStoreError.configuration("saved event has no identifier")
        }
        return a
    }

    public func update(localID: String, content: EventContent) throws -> AppleCalEvent {
        guard let ev = store.calendarItem(withIdentifier: localID) as? EKEvent, isSynced(ev) else { throw AppleStoreError.notFound }
        guard !ev.hasRecurrenceRules && !ev.isDetached else {
            throw AppleStoreError.notEditable("recurring events are only synced from Apple to Google")
        }
        guard ev.calendar.allowsContentModifications else {
            throw AppleStoreError.notEditable("calendar \"\(ev.calendar.title)\" is read-only")
        }
        apply(content, to: ev)
        try store.save(ev, span: .thisEvent, commit: true)
        guard let a = appleEvent(from: ev) else { throw AppleStoreError.notFound }
        return a
    }

    public func delete(localID: String) throws {
        // An event that left the synced calendars is no longer ours to delete.
        guard let ev = store.calendarItem(withIdentifier: localID) as? EKEvent, isSynced(ev) else { return }
        guard !ev.hasRecurrenceRules && !ev.isDetached else {
            throw AppleStoreError.notEditable("refusing to delete a recurring event")
        }
        guard ev.calendar.allowsContentModifications else {
            throw AppleStoreError.notEditable("calendar \"\(ev.calendar.title)\" is read-only")
        }
        try store.remove(ev, span: .thisEvent, commit: true)
    }

    // MARK: - Conversion

    private func appleEvent(from ev: EKEvent) -> AppleCalEvent? {
        guard let ext = ev.calendarItemExternalIdentifier, !ext.isEmpty,
              let start = ev.startDate, let end = ev.endDate else {
            Log.warning("skipping an Apple event without identifier or dates")
            return nil
        }
        let recurring = ev.hasRecurrenceRules || ev.isDetached
        var occurrence: String?
        if recurring {
            // The original date of this occurrence: stable even when the occurrence itself is moved.
            let date = ev.occurrenceDate ?? start
            occurrence = ev.isAllDay ? DayString.string(from: date, in: timeZone) : EventKitStore.utcStamp(date)
        }
        let timing: EventTiming
        if ev.isAllDay {
            let startDay = DayString.string(from: start, in: timeZone)
            // EventKit ends an all-day event at 23:59:59 of its last day; Google wants the day after.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let endsAtMidnight = cal.startOfDay(for: end) == end && end > start
            let lastDay = DayString.string(from: end, in: timeZone)
            var endExclusive = endsAtMidnight ? lastDay : (DayString.adding(days: 1, to: lastDay) ?? lastDay)
            if endExclusive <= startDay { endExclusive = DayString.adding(days: 1, to: startDay) ?? startDay }
            timing = .allDay(startDay: startDay, endDayExclusive: endExclusive)
        } else {
            timing = .timed(start: start, end: max(end, start))
        }
        let content = EventContent(title: ev.title ?? "", timing: timing, location: ev.location, notes: ev.notes,
                                   isFree: ev.availability == .free, timeZoneID: ev.timeZone?.identifier)
        return AppleCalEvent(calendarID: ev.calendar.calendarIdentifier, externalID: ext,
                          localID: ev.calendarItemIdentifier, occurrence: occurrence, isRecurring: recurring,
                          content: content, lastModified: ev.lastModifiedDate,
                          isReadOnly: !ev.calendar.allowsContentModifications)
    }

    private func apply(_ content: EventContent, to ev: EKEvent) {
        let c = content.normalized
        ev.title = c.title
        ev.location = c.location
        ev.notes = c.notes
        switch content.timing {
        case .allDay(let startDay, let endExclusive):
            ev.isAllDay = true
            let start = DayString.date(from: startDay, in: timeZone) ?? Date()
            let endMidnight = DayString.date(from: endExclusive, in: timeZone) ?? start.addingTimeInterval(86400)
            ev.startDate = start
            ev.endDate = max(start, endMidnight.addingTimeInterval(-1))
            ev.timeZone = nil
        case .timed(let start, let end):
            ev.isAllDay = false
            ev.startDate = start
            ev.endDate = max(start, end)
            if let id = content.timeZoneID, let tz = TimeZone(identifier: id) { ev.timeZone = tz }
        }
        // Not every calendar type can store free/busy; setting an unsupported value fails the save.
        let supported = ev.calendar.supportedEventAvailabilities
        if content.isFree, supported.contains(.free) {
            ev.availability = .free
        } else if !content.isFree, ev.availability == .free, supported.contains(.busy) {
            ev.availability = .busy
        }
    }

    static func utcStamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Same text the Python version produced, so its copies can be adopted.
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
