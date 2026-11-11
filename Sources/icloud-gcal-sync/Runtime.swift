import AppleCalendar
import Foundation
import GoogleCalendar
import SyncCore
import SyncStorage

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Everything one sync cycle needs, wired together.
final class Runtime {
    let paths: AppPaths
    let config: SyncConfig
    let store: SQLiteStateStore
    let authorizer: GoogleAuthorizer
    let transport: URLSessionTransport
    let apple: EventKitStore
    private var engine: SyncEngine?
    /// The calendar the cached engine talks to.
    private var engineCalendarID: String?
    private var consecutiveFailures = 0

    init(paths: AppPaths) throws {
        self.paths = paths
        try paths.ensureDirectories()
        config = try SyncConfig.load(from: paths.config)
        guard FileManager.default.fileExists(atPath: paths.googleClient.path) else {
            throw CLIError("Google OAuth client file not found. Download a \"Desktop app\" client from Google Cloud Console "
                + "and save it as \(paths.googleClient.path) (see README).")
        }
        let client = try OAuthClient.load(from: paths.googleClient)
        store = try SQLiteStateStore(url: paths.database)
        transport = URLSessionTransport()
        authorizer = GoogleAuthorizer(client: client, tokenFile: paths.googleToken, transport: transport)
        apple = EventKitStore(config: config)
    }

    /// Find (or create) the mirror calendar in Google. If it is not the one used last time,
    /// start over with clean pairings rather than treat every Apple event's copy as deleted.
    /// With `persist` false nothing is written locally (dry run).
    func ensureGoogleCalendar(create: Bool, persist: Bool = true) throws -> String? {
        let stored = try store.meta(MetaKey.googleCalendarID)
        let directory = GoogleCalendarDirectory(authorizer: authorizer, transport: transport)
        guard let id = try directory.ensureCalendar(name: config.googleCalendarName, storedID: stored, create: create) else {
            return nil
        }
        if id != stored && persist {
            if stored != nil {
                Log.warning("the Google calendar \"\(config.googleCalendarName)\" was replaced; starting over with a fresh copy")
                try SyncEngine.resetGoogleState(in: store)
            }
            try store.setMeta(MetaKey.googleCalendarID, id)
        }
        return id
    }

    private func makeEngine(dryRun: Bool) throws -> SyncEngine {
        if dryRun {
            let stored = try store.meta(MetaKey.googleCalendarID)
            if let id = try ensureGoogleCalendar(create: false, persist: false), id == stored {
                return SyncEngine(apple: apple, google: GoogleCalendarClient(calendarID: id, authorizer: authorizer, transport: transport),
                                  store: store, config: config)
            }
            // The calendar does not exist yet or was replaced: a real run would start from
            // scratch, so preview exactly that without touching the real state.
            Log.info("the Google calendar would be created; previewing a first full copy")
            return SyncEngine(apple: apple, google: EmptyGoogleCalendar(), store: try SQLiteStateStore.inMemory(), config: config)
        }
        // Checked every cycle (one small request): the calendar can be deleted or replaced
        // while the daemon runs, and the engine must never keep talking to a stale one.
        guard let id = try ensureGoogleCalendar(create: true) else {
            throw CLIError("could not find or create the Google calendar \"\(config.googleCalendarName)\"")
        }
        if let engine, engineCalendarID == id { return engine }
        let made = SyncEngine(apple: apple, google: GoogleCalendarClient(calendarID: id, authorizer: authorizer, transport: transport),
                              store: store, config: config)
        engine = made
        engineCalendarID = id
        return made
    }

    /// One full cycle. Throws only for failures that stop the whole run.
    func cycle(_ options: SyncEngine.Options) throws -> SyncEngine.Report {
        switch EventKitStore.access {
        case .granted: break
        case .notDetermined:
            guard apple.requestAccess() == .granted else {
                throw AppleStoreError.accessDenied("calendar access was not granted")
            }
        case .denied:
            throw AppleStoreError.accessDenied("allow icloud-gcal-sync under System Settings > Privacy & Security > Calendars")
        }
        // A process that runs for weeks must notice the Mac changing time zone: all-day
        // dates and the window are computed with it.
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        apple.timeZone = zone
        // Resolved every cycle: calendars can be renamed, added or deleted while the daemon runs.
        let storedTarget = try store.meta(MetaKey.appleTargetCalendarID)
        let target = try apple.resolveCalendars(storedTargetID: storedTarget, createTarget: !options.dryRun)
        if let target, target != storedTarget, !options.dryRun {
            try store.setMeta(MetaKey.appleTargetCalendarID, target)
        }
        let engine = try makeEngine(dryRun: options.dryRun)
        engine.timeZone = zone
        return try engine.runOnce(options)
    }

    /// Run a cycle under the cross-process lock, log the outcome and raise notifications.
    @discardableResult
    func lockedCycle(_ options: SyncEngine.Options) -> CycleOutcome {
        guard let lock = FileLock(paths.lock) else {
            Log.warning("another sync is running; skipping this cycle")
            return .busy
        }
        defer { lock.unlock() }
        do {
            let report = try cycle(options)
            if let reason = report.blockedReason {
                Log.error("\(reason); nothing was changed. If this is intended run: icloud-gcal-sync sync --allow-mass-delete")
                Notifier.post("Sync paused: \(reason)", category: "blocked", paths: paths)
                return .blocked(reason)
            }
            if !report.failures.isEmpty {
                let message = "\(report.failures.count) events could not be synced"
                failed("Sync finished with \(report.failures.count) errors. Check \(paths.logFile.path)")
                return .failed(message)
            }
            consecutiveFailures = 0
            if report.plan.actions.contains(where: { $0.writesCalendar }) || options.dryRun {
                Log.info("done\(options.dryRun ? " (dry run, nothing written)" : "")")
            }
            return .ok(report)
        } catch let error as GoogleAPIError {
            Log.error("sync failed: \(error)")
            if case .unauthorized = error {
                Notifier.post("Google sign-in expired. Sign in from the menu bar icon, or run: icloud-gcal-sync auth", category: "auth", paths: paths)
                return .needsGoogleAuthorization
            }
            failed("Sync failed: \(error)")
            return .failed("\(error)")
        } catch let error as AppleStoreError {
            Log.error("sync failed: \(error)")
            if case .accessDenied = error {
                Notifier.post("No access to Apple Calendar: \(error)", category: "access", paths: paths)
                return .noCalendarAccess
            }
            failed("Sync failed: \(error)")
            return .failed("\(error)")
        } catch {
            Log.error("sync failed: \(error)")
            failed("Sync failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// Being offline for a moment after wake is normal; only a failure that persists is worth an alert.
    private func failed(_ message: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= 3 { Notifier.post(message, category: "failed", paths: paths) }
    }
}

enum CycleOutcome {
    case ok(SyncEngine.Report)
    /// A mass-delete guard refused the plan; nothing was changed.
    case blocked(String)
    case needsGoogleAuthorization
    case noCalendarAccess
    case failed(String)
    /// Another process was syncing.
    case busy

    var succeeded: Bool { if case .ok = self { return true }; return false }
}

/// macOS notifications, throttled per kind of problem so that a harmless repeated failure
/// cannot use up the alert a serious one needs.
enum Notifier {
    static func post(_ message: String, category: String, paths: AppPaths, everyHours: Double = 6) {
        let stamp = paths.logDir.appendingPathComponent(".last_alert_\(category)")
        if let modified = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < everyHours * 3600 {
            return
        }
        FileManager.default.createFile(atPath: stamp.path, contents: nil)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: stamp.path)
        // The text is passed as an argument, never spliced into the script, so nothing in an
        // error message or event title can be interpreted as AppleScript.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"iCloud ⇄ Google sync\"",
                       "-e", "end run", String(message.prefix(200))]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Stands in for the mirror calendar during a dry run made before the calendar exists.
final class EmptyGoogleCalendar: GoogleCalendarAPI {
    func changes(since syncToken: String?) throws -> GoogleDelta { GoogleDelta(events: [], nextSyncToken: nil, isFull: true) }
    func insert(_ content: EventContent, mirrorKey: String?) throws -> GoogleEvent { throw GoogleAPIError.notFound }
    func patch(id: String, content: EventContent, mirrorKey: String?) throws -> GoogleEvent { throw GoogleAPIError.notFound }
    func delete(id: String) throws {}
}

/// Advisory lock so the daemon and a manual `sync` never run a cycle at the same time.
final class FileLock {
    private let fd: Int32
    init?(_ url: URL) {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }
    func unlock() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
