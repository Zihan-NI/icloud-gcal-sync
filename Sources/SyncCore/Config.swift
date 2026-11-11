import Foundation

public struct SyncConfig: Codable, Equatable, Sendable {
    /// Title of the account in Apple Calendar whose calendars are synced.
    public var appleSource: String = "iCloud"
    /// Calendar titles to mirror to Google. Empty = every event calendar of `appleSource`.
    public var icloudCalendars: [String] = []
    /// Calendar (in `appleSource`) that receives events created in Google. Created if missing.
    public var appleTargetCalendar: String = "From Google"
    public var googleCalendarName: String = "iCloud Sync"
    public var pastDays: Int = 30
    public var futureDays: Int = 365
    /// Mass-delete guard for Google copies.
    public var maxDeletesPerRun: Int = 50
    /// Mass-delete guard for Apple events (deletions that originate in Google).
    public var maxAppleDeletesPerRun: Int = 10
    public var googlePollSeconds: Int = 60
    public var debounceSeconds: Double = 5
    /// What to do when both copies of a two-way event were edited between runs.
    public var conflictPolicy: ConflictPolicy = .newest

    public enum ConflictPolicy: String, Codable, Sendable {
        /// The copy edited most recently wins; Apple wins when that cannot be determined.
        case newest
        /// The Apple copy always wins.
        case apple
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case appleSource = "apple_source"
        case icloudCalendars = "icloud_calendars"
        case appleTargetCalendar = "apple_target_calendar"
        case googleCalendarName = "google_calendar_name"
        case pastDays = "past_days"
        case futureDays = "future_days"
        case maxDeletesPerRun = "max_deletes_per_run"
        case maxAppleDeletesPerRun = "max_apple_deletes_per_run"
        case googlePollSeconds = "google_poll_seconds"
        case debounceSeconds = "debounce_seconds"
        case conflictPolicy = "conflict_policy"
    }

    /// Every key is optional; unknown keys (e.g. `icloud_username` from the Python version) are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncConfig()
        appleSource = try c.decodeIfPresent(String.self, forKey: .appleSource) ?? d.appleSource
        icloudCalendars = try c.decodeIfPresent([String].self, forKey: .icloudCalendars) ?? d.icloudCalendars
        appleTargetCalendar = try c.decodeIfPresent(String.self, forKey: .appleTargetCalendar) ?? d.appleTargetCalendar
        googleCalendarName = try c.decodeIfPresent(String.self, forKey: .googleCalendarName) ?? d.googleCalendarName
        pastDays = try c.decodeIfPresent(Int.self, forKey: .pastDays) ?? d.pastDays
        futureDays = try c.decodeIfPresent(Int.self, forKey: .futureDays) ?? d.futureDays
        maxDeletesPerRun = try c.decodeIfPresent(Int.self, forKey: .maxDeletesPerRun) ?? d.maxDeletesPerRun
        maxAppleDeletesPerRun = try c.decodeIfPresent(Int.self, forKey: .maxAppleDeletesPerRun) ?? d.maxAppleDeletesPerRun
        googlePollSeconds = try c.decodeIfPresent(Int.self, forKey: .googlePollSeconds) ?? d.googlePollSeconds
        debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? d.debounceSeconds
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? d.conflictPolicy
    }

    public static func load(from url: URL) throws -> SyncConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncConfig() }
        return try JSONDecoder().decode(SyncConfig.self, from: Data(contentsOf: url))
    }

    public func window(now: Date = Date(), timeZone: TimeZone = .current) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -pastDays, to: today) ?? today
        let end = cal.date(byAdding: .day, value: futureDays, to: today) ?? today
        return DateInterval(start: start, end: end)
    }
}

/// Where everything lives on disk. Override the root with `ICLOUD_GCAL_SYNC_HOME` or `--home`.
public struct AppPaths: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        if let root { self.root = root; return }
        if let env = ProcessInfo.processInfo.environment["ICLOUD_GCAL_SYNC_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            return
        }
        self.root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/icloud-gcal-sync", isDirectory: true)
    }
    public var config: URL { root.appendingPathComponent("config.json") }
    /// OAuth client downloaded from Google Cloud Console ("Desktop app").
    public var googleClient: URL { root.appendingPathComponent("credentials.json") }
    public var googleToken: URL { root.appendingPathComponent("token.json") }
    public var database: URL { root.appendingPathComponent("state.sqlite") }
    public var lock: URL { root.appendingPathComponent(".sync.lock") }
    public var logDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var logFile: URL { logDir.appendingPathComponent("sync.log") }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
