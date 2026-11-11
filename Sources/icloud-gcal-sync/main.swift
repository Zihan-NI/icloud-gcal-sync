import AppleCalendar
import Foundation
import GoogleCalendar
import SyncCore
import SyncStorage

let usage = """
icloud-gcal-sync: two-way sync between Apple Calendar (iCloud) and a dedicated Google calendar.

Usage: icloud-gcal-sync <command> [options]

Commands:
  auth        Authorize Google in the browser and create the Google calendar
  calendars   List Apple calendars and show which ones are synced
  sync        Run one sync now
  run         Stay running: sync on every Apple Calendar change and poll Google (used by launchd).
              Shows a menu bar icon with status, Sync Now and setup
  status      Show configuration and the state of the last sync

Options:
  --dry-run             (sync) show what would change without writing anything
  --allow-mass-delete   (sync) bypass the mass-deletion guards for this run
  --headless            (run) no menu bar icon
  --home DIR            use DIR instead of ~/Library/Application Support/icloud-gcal-sync
  -v, --verbose         more logging
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ names: String...) -> Bool {
    let found = args.contains { names.contains($0) }
    args.removeAll { names.contains($0) }
    return found
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let verbose = flag("-v", "--verbose")
let dryRun = flag("--dry-run")
let allowMassDelete = flag("--allow-mass-delete")
let headless = flag("--headless")
let paths = AppPaths(root: option("--home").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) })
if flag("-h", "--help") || args.isEmpty {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
let command = args.removeFirst()
if let extra = args.first { fail("unexpected argument \"\(extra)\"\n\n\(usage)") }

try? paths.ensureDirectories()
// Under launchd stderr is an unrotated file, so only the rotated log gets the messages there.
Log.configure(file: paths.logFile, verbose: verbose, echoToStderr: isatty(STDERR_FILENO) != 0)

do {
    switch command {
    case "auth":
        let rt = try Runtime(paths: paths)
        print("A browser window will open; sign in with the Google account to sync with.")
        try rt.authorizer.authorizeInteractively()
        let id = try rt.ensureGoogleCalendar(create: true) ?? "?"
        print("Google calendar ready: \(rt.config.googleCalendarName) (\(id))")
        print("Next: scripts/install.sh, or try `icloud-gcal-sync sync --dry-run`.")

    case "calendars":
        // Needs neither Google credentials nor a database: it is the first thing to try.
        let config = try SyncConfig.load(from: paths.config)
        let apple = EventKitStore(config: config)
        guard apple.requestAccess() == .granted else {
            fail("no calendar access for this process. Run from a terminal that may access Calendars, or check System Settings > Privacy & Security > Calendars.")
        }
        var storedTarget: String?
        if FileManager.default.fileExists(atPath: paths.database.path) {
            storedTarget = try SQLiteStateStore(url: paths.database).meta(MetaKey.appleTargetCalendarID)
        }
        try apple.resolveCalendars(storedTargetID: storedTarget, createTarget: false)
        for c in apple.describeCalendars().sorted(by: { ($0.source, $0.title) < ($1.source, $1.title) }) {
            let mark = c.isTarget ? "⇄ target" : (c.synced ? "⇄ synced" : "  -")
            print("\(mark.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.source) / \(c.title)\(c.writable ? "" : " (read-only)")")
        }
        print("\nEvents created in Google go to \"\(config.appleTargetCalendar)\" in \(config.appleSource)"
            + " (created on the first sync if it does not exist).")

    case "sync":
        let rt = try Runtime(paths: paths)
        let outcome = rt.lockedCycle(SyncEngine.Options(dryRun: dryRun, allowMassDelete: allowMassDelete))
        exit(outcome.succeeded ? 0 : 1)

    case "run":
        // Kept in a variable: the daemon's timer and observers refer back to it for the life of the process.
        let daemon = Daemon(paths: paths)
        daemon.run(menuBar: !headless)

    case "status":
        print("home:             \(paths.root.path)")
        print("calendar access:  \(EventKitStore.access.rawValue) (for this process; the launchd job has its own)")
        print("Google client:    \(FileManager.default.fileExists(atPath: paths.googleClient.path) ? "present" : "missing")")
        print("Google token:     \(FileManager.default.fileExists(atPath: paths.googleToken.path) ? "present" : "missing (run: icloud-gcal-sync auth)")")
        if FileManager.default.fileExists(atPath: paths.database.path) {
            let store = try SQLiteStateStore(url: paths.database)
            let links = try store.allLinks()
            print("Google calendar:  \(try store.meta(MetaKey.googleCalendarID) ?? "not created yet")")
            print("last success:     \(try store.meta(MetaKey.lastSuccess) ?? "never")")
            print("paired events:    \(links.count) (\(links.filter { $0.mode == .twoWay }.count) two-way, "
                + "\(links.filter { $0.origin == .google }.count) created in Google)")
        } else {
            print("no sync has run yet")
        }

    default:
        fail("unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    Log.error("\(error)")
    if isatty(STDERR_FILENO) == 0 { FileHandle.standardError.write(Data("error: \(error)\n".utf8)) }
    exit(1)
}
