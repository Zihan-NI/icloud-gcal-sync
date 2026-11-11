import Foundation

/// Runs one sync cycle: read both sides, plan, check the guards, apply.
///
/// Nothing is written anywhere until both sides have been read successfully, so a failure
/// to read Apple Calendar or Google can never be mistaken for "everything was deleted".
public final class SyncEngine {
    public struct Options: Sendable {
        public var dryRun = false
        public var allowMassDelete = false
        public init(dryRun: Bool = false, allowMassDelete: Bool = false) {
            self.dryRun = dryRun
            self.allowMassDelete = allowMassDelete
        }
    }

    public struct Report: Sendable {
        public var appleCount = 0
        public var googleCount = 0
        public var plan = Plan()
        /// Set when a guard refused the plan. Nothing was applied.
        public var blockedReason: String?
        /// Actions that failed. The run is then not recorded as a success, and they are retried next cycle.
        public var failures: [String] = []
        public var applied = 0
        public var succeeded: Bool { blockedReason == nil && failures.isEmpty }
    }

    private let apple: AppleCalendarStore
    private let google: GoogleCalendarAPI
    private let store: SyncStateStore
    private let config: SyncConfig
    private let now: () -> Date
    /// Set again before each cycle by a long-running process: the Mac can change time zone
    /// while the daemon is up, and all-day dates and the window depend on it.
    public var timeZone: TimeZone

    public init(apple: AppleCalendarStore, google: GoogleCalendarAPI, store: SyncStateStore, config: SyncConfig,
                now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.apple = apple
        self.google = google
        self.store = store
        self.config = config
        self.now = now
        self.timeZone = timeZone
    }

    public func runOnce(_ options: Options = Options()) throws -> Report {
        var report = Report()
        let started = now()
        let window = config.window(now: started, timeZone: timeZone)

        // 1. Read Apple.
        var appleEvents = try apple.snapshot(window: window)
        report.appleCount = appleEvents.count

        // 2. Read Google (incrementally when possible) and bring the local cache up to date.
        let googleEvents = try refreshGoogleCache(persist: !options.dryRun)
        report.googleCount = googleEvents.count

        // 3. A linked single event missing from the snapshot may only have moved out of the
        //    window. Ask for it directly so "moved" is not mistaken for "deleted".
        var links = try store.allLinks()
        var present = Set(appleEvents.map(\.key))
        let linkedKeys = Set(links.map(\.appleKey))
        var lookedUp = Set<String>()
        for i in links.indices where links[i].mode == .twoWay && !present.contains(links[i].appleKey)
            && links[i].startTS >= window.start.timeIntervalSince1970 {
            let link = links[i]
            lookedUp.insert(link.appleKey)
            guard let found = try apple.lookup(localID: link.appleLocalID) else { continue }
            if found.key != link.appleKey {
                // Same event under a new key: it was moved to another synced calendar. Keep
                // the pairing and follow it, rather than delete one copy and create another.
                guard found.syncsBothWays, !linkedKeys.contains(found.key), !lookedUp.contains(found.key) else { continue }
                links[i].appleKey = found.key
                links[i].appleCalendarID = found.calendarID
                links[i].appleExternalID = found.externalID
                lookedUp.insert(found.key)
                if !options.dryRun { try store.updateLink(links[i]) }
            }
            if present.insert(found.key).inserted { appleEvents.append(found) }
        }

        // 4. Plan and check.
        let plan = Planner.plan(apple: appleEvents, lookedUp: lookedUp, google: googleEvents, links: links,
                                window: window, policy: config.conflictPolicy, timeZone: timeZone)
        report.plan = plan
        // An idle cycle runs every minute; only say something when there is something to do.
        let summary = "plan: \(plan.summary) (Apple=\(report.appleCount), Google=\(report.googleCount), links=\(links.count))"
        if plan.actions.isEmpty && !options.dryRun { Log.debug(summary) } else { Log.info(summary) }
        for c in plan.conflicts { Log.warning("conflict: \(c)") }
        if plan.skippedRecurringGoogle > 0 {
            Log.debug("\(plan.skippedRecurringGoogle) recurring events created in Google are not copied to Apple Calendar")
        }

        if !options.allowMassDelete {
            let previous = try store.meta(MetaKey.prevAppleCount).flatMap { Int($0) }
            if let reason = deletionGuard(plan: plan, appleCount: report.appleCount, googleCount: report.googleCount,
                                          previousAppleCount: previous, config: config) {
                report.blockedReason = reason
                return report
            }
        }
        if options.dryRun {
            for action in plan.actions where action.writesCalendar { Log.info("would: \(describe(action))") }
            return report
        }

        // 5. Apply. One failing event must not stop the others; authorization failures stop everything.
        for action in plan.actions {
            do {
                try perform(action, at: started)
                report.applied += 1
            } catch let error as GoogleAPIError {
                if case .unauthorized = error { throw error }
                report.failures.append("\(describe(action)): \(error)")
                Log.error("failed: \(describe(action)): \(error)")
            } catch {
                report.failures.append("\(describe(action)): \(error)")
                Log.error("failed: \(describe(action)): \(error)")
            }
        }

        // The guard's baseline is "what Apple held when a plan was last accepted". It must
        // advance even when single actions failed, or one permanently failing event would
        // freeze it and blunt the guard.
        try store.setMeta(MetaKey.prevAppleCount, String(report.appleCount))
        if report.failures.isEmpty {
            try store.setMeta(MetaKey.lastSuccess, ISO8601DateFormatter().string(from: started))
        }
        return report
    }

    /// Forget everything known about the Google calendar and the pairings. Used when the
    /// mirror calendar was replaced by a new one: every Apple event is then simply copied again
    /// and nothing is deleted on the Apple side.
    public static func resetGoogleState(in store: SyncStateStore) throws {
        try store.transaction {
            for link in try store.allLinks() { if let id = link.id { try store.deleteLink(id: id) } }
            try store.replaceGoogleEvents([])
            try store.setMeta(MetaKey.googleSyncToken, nil)
            try store.setMeta(MetaKey.prevAppleCount, nil)
        }
    }

    // MARK: - Google cache

    private func refreshGoogleCache(persist: Bool) throws -> [GoogleEvent] {
        let token = try store.meta(MetaKey.googleSyncToken)
        var delta: GoogleDelta
        do {
            delta = try google.changes(since: token)
        } catch GoogleAPIError.syncTokenExpired {
            Log.info("Google sync token expired; listing the whole calendar")
            delta = try google.changes(since: nil)
        }

        var cache: [String: GoogleEvent] = [:]
        if delta.isFull {
            for e in delta.events where !e.isCancelled { cache[e.id] = e }
        } else {
            for e in try store.allGoogleEvents() { cache[e.id] = e }
            for e in delta.events {
                if e.isCancelled { cache[e.id] = nil } else { cache[e.id] = e }
            }
        }
        if persist {
            // The token and the cache move together, or the next incremental pass would
            // skip changes the cache never saw.
            try store.transaction {
                if delta.isFull {
                    try store.replaceGoogleEvents(Array(cache.values))
                } else {
                    for e in delta.events {
                        if e.isCancelled { try store.deleteGoogleEvent(id: e.id) } else { try store.upsertGoogleEvent(e) }
                    }
                }
                if let next = delta.nextSyncToken { try store.setMeta(MetaKey.googleSyncToken, next) }
            }
        }
        return Array(cache.values)
    }

    // MARK: - Applying actions

    private func perform(_ action: SyncAction, at time: Date) throws {
        switch action {
        case .createGoogle(let a):
            Log.info(describe(action))
            let g = try google.insert(a.content, mirrorKey: a.key)
            try store.transaction {
                try store.upsertGoogleEvent(g)
                _ = try store.insertLink(makeLink(origin: .apple, apple: a, google: g, at: time))
            }

        case .adopt(let a, var g):
            if action.writesCalendar {
                Log.info(describe(action))
                g = try google.patch(id: g.id, content: a.content, mirrorKey: a.key)
            }
            try store.transaction {
                try store.upsertGoogleEvent(g)
                _ = try store.insertLink(makeLink(origin: .apple, apple: a, google: g, at: time))
            }

        case .updateGoogle(var link, let a):
            Log.info(describe(action))
            let g: GoogleEvent
            do {
                // A mirror copy keeps its marker; an event that was created in Google stays unmarked.
                g = try google.patch(id: link.googleEventID, content: a.content,
                                     mirrorKey: link.origin == .apple ? a.key : nil)
            } catch GoogleAPIError.notFound {
                g = try google.insert(a.content, mirrorKey: a.key)
                link.origin = .apple
            }
            link.googleEventID = g.id
            try save(&link, apple: a, google: g, at: time)

        case .recreateGoogle(var link, let a):
            Log.info(describe(action))
            let g = try google.insert(a.content, mirrorKey: a.key)
            link.googleEventID = g.id
            link.origin = .apple
            try save(&link, apple: a, google: g, at: time)

        case .deleteGoogle(let link, let googleID):
            Log.info(describe(action))
            try google.delete(id: googleID)
            try store.transaction {
                try store.deleteGoogleEvent(id: googleID)
                if let id = link?.id { try store.deleteLink(id: id) }
            }

        case .createApple(let g):
            guard let content = g.content else { return }
            Log.info(describe(action))
            let a = try apple.create(content)
            _ = try store.insertLink(makeLink(origin: .google, apple: a, google: g, at: time))

        case .updateApple(var link, let g, let current):
            guard let content = g.content else { return }
            Log.info(describe(action))
            let a: AppleCalEvent
            do {
                a = try apple.update(localID: current.localID, content: content)
            } catch AppleStoreError.notFound {
                a = try apple.create(content)
            }
            try save(&link, apple: a, google: g, at: time)

        case .recreateApple(var link, let g):
            guard let content = g.content else { return }
            Log.info(describe(action))
            let a = try apple.create(content)
            try save(&link, apple: a, google: g, at: time)

        case .deleteApple(let link, let current):
            Log.info(describe(action))
            try apple.delete(localID: current.localID)
            if let id = link.id { try store.deleteLink(id: id) }

        case .pair(let a, let g):
            _ = try store.insertLink(makeLink(origin: .google, apple: a, google: g, at: time))

        case .refreshBaselines(var link, let a, let g):
            try save(&link, apple: a, google: g, at: time)

        case .dropLink(let link):
            if let id = link.id { try store.deleteLink(id: id) }
        }
    }

    private func mode(for a: AppleCalEvent) -> Link.Mode { a.syncsBothWays ? .twoWay : .oneWay }

    private func makeLink(origin: Link.Origin, apple a: AppleCalEvent, google g: GoogleEvent, at time: Date) -> Link {
        Link(origin: origin, mode: mode(for: a), appleKey: a.key, appleCalendarID: a.calendarID,
             appleExternalID: a.externalID, appleLocalID: a.localID, occurrence: a.occurrence, googleEventID: g.id,
             appleHash: a.content.contentHash, googleHash: (g.content ?? a.content).contentHash,
             startTS: a.content.timing.startInstant(in: timeZone).timeIntervalSince1970, lastSyncedAt: time)
    }

    /// Record that the two sides agree as of now, each with its own baseline hash.
    private func save(_ link: inout Link, apple a: AppleCalEvent, google g: GoogleEvent, at time: Date) throws {
        link.mode = mode(for: a)
        link.appleKey = a.key
        link.appleCalendarID = a.calendarID
        link.appleExternalID = a.externalID
        link.appleLocalID = a.localID
        link.occurrence = a.occurrence
        link.appleHash = a.content.contentHash
        link.googleHash = (g.content ?? a.content).contentHash
        link.startTS = a.content.timing.startInstant(in: timeZone).timeIntervalSince1970
        link.lastSyncedAt = time
        let updated = link
        try store.transaction {
            try store.upsertGoogleEvent(g)
            try store.updateLink(updated)
        }
    }

    private func describe(_ action: SyncAction) -> String {
        func when(_ c: EventContent?) -> String {
            guard let c else { return "?" }
            switch c.timing {
            case .allDay(let s, _): return s
            case .timed(let s, _):
                let f = ISO8601DateFormatter()
                f.timeZone = timeZone
                return f.string(from: s)
            }
        }
        func label(_ c: EventContent?) -> String { "\(when(c))  \(c?.normalized.title ?? "?")" }
        switch action {
        case .createGoogle(let a): return "CREATE in Google  \(label(a.content))"
        case .adopt(let a, _): return "ADOPT Google copy  \(label(a.content))"
        case .updateGoogle(_, let a): return "UPDATE in Google  \(label(a.content))"
        case .recreateGoogle(_, let a): return "RESTORE in Google  \(label(a.content))"
        case .deleteGoogle(_, let id): return "DELETE in Google  \(id)"
        case .createApple(let g): return "CREATE in Apple  \(label(g.content))"
        case .updateApple(_, let g, _): return "UPDATE in Apple  \(label(g.content))"
        case .recreateApple(_, let g): return "RESTORE in Apple  \(label(g.content))"
        case .deleteApple(_, let a): return "DELETE in Apple  \(label(a.content))"
        case .pair(let a, _): return "PAIR \(a.key)"
        case .refreshBaselines(let link, _, _): return "REFRESH \(link.appleKey)"
        case .dropLink(let link): return "FORGET \(link.appleKey)"
        }
    }
}

public enum AppleStoreError: Error, Equatable, CustomStringConvertible {
    case notFound
    case accessDenied(String)
    case configuration(String)
    case notEditable(String)

    public var description: String {
        switch self {
        case .notFound: return "Apple event not found"
        case .accessDenied(let m): return "no access to Apple Calendar: \(m)"
        case .configuration(let m): return m
        case .notEditable(let m): return "Apple event cannot be changed: \(m)"
        }
    }
}
