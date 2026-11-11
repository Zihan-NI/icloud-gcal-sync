import AppKit
import AppleCalendar
import Foundation
import GoogleCalendar
import SyncCore

/// What the menu bar shows. Built on the cycle queue, handed to the main thread.
struct DaemonStatus {
    enum State: Equatable {
        case starting
        /// credentials.json is missing: the user has to choose one.
        case needsCredentials
        /// The program cannot start for another reason (for example a broken config.json).
        case cannotStart(String)
        /// Not signed in, with the reason the last attempt failed if there was one.
        case needsGoogleAuthorization(String?)
        case noCalendarAccess
        case syncing
        case idle
        /// A mass-delete guard refused the last plan.
        case paused(String)
        case failed(String)
    }
    var state: State = .starting
    /// A browser sign-in is waiting for the user. Independent of `state`: when switching
    /// accounts the old sign-in keeps syncing until the new one is complete.
    var signingIn = false
    var lastSuccess: Date?
    var pairedEvents = 0
    var createdInGoogle = 0
    var googleCalendarName = ""
    var appleTargetCalendar = ""
}

/// Long-running mode: sync when Apple Calendar reports a change, and poll Google on a timer.
///
/// Both triggers run the same full cycle. Reading Apple Calendar is local and reading Google
/// is incremental, so a cycle with nothing to do costs one small request.
final class Daemon {
    let paths: AppPaths
    private var runtime: Runtime?
    private let queue = DispatchQueue(label: "icloud-gcal-sync.cycle")
    private var debounce: DispatchWorkItem?
    private var firstPendingChange: Date?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var debounceSeconds = 5.0
    /// A burst of change notifications must not postpone the sync forever.
    private let maxDebounceWait = 30.0
    private var status = DaemonStatus()
    /// Decided once, before any work starts, so both threads agree on it.
    private var showsMenuBar = false
    /// Main thread only.
    private var menuBar: MenuBarController?
    /// The browser sign-in in progress, if any. Cycle queue only.
    private var signIn: SignInAttempt?

    init(paths: AppPaths) { self.paths = paths }

    func run(menuBar showMenuBar: Bool) -> Never {
        // Not on the cycle queue: a stop request must not wait behind a long cycle.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Log.info("stopping")
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
        Log.info("started (calendar access: \(EventKitStore.access.rawValue))")
        showsMenuBar = showMenuBar
        if showMenuBar {
            NSApplication.shared.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no main menu
            menuBar = MenuBarController(daemon: self)
        }
        queue.async {
            self.startRuntime()
            if EventKitStore.access == .notDetermined, let rt = self.runtime {
                Log.info("asking for calendar access; answer the macOS prompt")
                _ = rt.apple.requestAccess()
            }
            self.schedulePolling(fireNow: true)
        }
        // Either way the main thread runs a real run loop, not dispatchMain(): EventKit
        // delivers its change notifications through run-loop sources, and without one
        // EKEventStoreChanged never arrives.
        if showMenuBar {
            NSApplication.shared.run()
            exit(0)
        }
        while true { RunLoop.main.run(until: .distantFuture) }
    }

    // MARK: - Commands from the menu (any thread)

    func syncNow() {
        queue.async { self.cycle() }
    }

    /// Re-read config.json and credentials.json, and compare against the whole Google
    /// calendar instead of only the changes since the last sync. Pairings are kept.
    func refresh() {
        queue.async {
            Log.info("refresh requested: reloading configuration and re-reading the whole Google calendar")
            self.runtime = nil
            self.startRuntime()
            guard let rt = self.runtime else { return }   // startRuntime has published why
            do {
                try rt.store.setMeta(MetaKey.googleSyncToken, nil)
            } catch {
                Log.error("refresh failed: \(error)")
                self.publish { $0.state = .failed("\(error)") }
                return
            }
            self.cycle()
        }
    }

    /// Install a new OAuth client file and sign in to Google with it.
    /// - Returns: nil when the file was accepted, otherwise a message for the user. Called on
    ///   the main thread; installing and signing in continue in the background.
    func useCredentials(from source: URL) -> String? {
        let hint = "In Google Cloud Console choose Clients → Create client → Desktop app → Download JSON."
        let data: Data
        let client: OAuthClient
        do {
            data = try Data(contentsOf: source)
            client = try OAuthClient.parse(data)
        } catch {
            return "This is not an OAuth client file for a Desktop app.\n\n\(hint)\n\n(\(error))"
        }
        guard !client.clientID.isEmpty, !client.clientSecret.isEmpty else {
            return "The file has no client ID or client secret.\n\n\(hint)"
        }
        queue.async {
            do {
                try self.paths.ensureDirectories()
                let sameClient = (try? OAuthClient.load(from: self.paths.googleClient))?.clientID == client.clientID
                // Written under a temporary name with its final permissions, then renamed over
                // the old file: the client secret is never readable by others, not even briefly.
                let destination = self.paths.googleClient.path, tmp = destination + ".tmp"
                try? FileManager.default.removeItem(atPath: tmp)
                guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
                      rename(tmp, destination) == 0 else {
                    try? FileManager.default.removeItem(atPath: tmp)
                    throw CLIError("could not write \(destination): \(String(cString: strerror(errno)))")
                }
                Log.info("installed a new Google OAuth client file")
                self.runtime = nil
                if sameClient && FileManager.default.fileExists(atPath: self.paths.googleToken.path) {
                    self.cycle()
                } else {
                    // A token only works with the client that obtained it.
                    try? FileManager.default.removeItem(at: self.paths.googleToken)
                    self.beginSignIn()
                }
            } catch {
                Log.error("could not install the credentials file: \(error)")
                self.publish { $0.state = .cannotStart("\(error)") }
            }
        }
        return nil
    }

    /// Sign in to Google in the browser (again, or with another account), then sync.
    func signInToGoogle() {
        queue.async { self.beginSignIn() }
    }

    func cancelSignIn() {
        queue.async { self.signIn?.cancel() }
    }

    // MARK: - Cycle queue

    /// The wait for the browser runs on its own thread, so syncing, polling and the menu stay
    /// responsive, and the user can cancel or start over at any time.
    private func beginSignIn() {
        signIn?.cancel()
        let client: OAuthClient
        do {
            client = try OAuthClient.load(from: paths.googleClient)
        } catch {
            signIn = nil
            publish { $0.signingIn = false; $0.state = .needsCredentials }
            return
        }
        let attempt = SignInAttempt()
        signIn = attempt
        publish { $0.signingIn = true }
        let authorizer = GoogleAuthorizer(client: client, tokenFile: paths.googleToken, transport: URLSessionTransport())
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try authorizer.authorizeInteractively(timeout: 300, isCancelled: { attempt.isCancelled })
            } catch let error as GoogleAPIError {
                if case .unauthorized(let message) = error { failure = message } else { failure = "\(error)" }
            } catch {
                failure = "\(error)"
            }
            self.queue.async {
                guard self.signIn === attempt else { return }   // replaced by a newer attempt
                self.signIn = nil
                let signedIn = FileManager.default.fileExists(atPath: self.paths.googleToken.path)
                if let failure, !attempt.isCancelled { Log.error("Google sign-in failed: \(failure)") }
                self.publish {
                    $0.signingIn = false
                    if !signedIn { $0.state = .needsGoogleAuthorization(attempt.isCancelled ? nil : failure) }
                }
                if failure == nil {
                    // The runtime holds the old sign-in in memory; start over with the new one.
                    self.runtime = nil
                }
                if signedIn { self.cycle() }
            }
        }
    }

    /// Build the runtime, or report why not. Called again each cycle until it succeeds, so
    /// that finishing the setup (adding credentials.json) does not need a restart.
    private func startRuntime() {
        guard runtime == nil else { return }
        do {
            let rt = try Runtime(paths: paths)
            runtime = rt
            debounceSeconds = max(1, rt.config.debounceSeconds)
            rt.apple.observeChanges { self.appleChanged() }
            if timer != nil { schedulePolling(fireNow: false) }   // the interval may have changed
            let last = (try? rt.store.meta(MetaKey.lastSuccess)).flatMap { $0 }.flatMap { ISO8601DateFormatter().date(from: $0) }
            let links = (try? rt.store.allLinks()) ?? []
            publish {
                $0.googleCalendarName = rt.config.googleCalendarName
                $0.appleTargetCalendar = rt.config.appleTargetCalendar
                $0.lastSuccess = $0.lastSuccess ?? last
                $0.pairedEvents = links.count
                $0.createdInGoogle = links.filter { $0.origin == .google }.count
            }
        } catch {
            Log.error("cannot start: \(error)")
            let missing = !FileManager.default.fileExists(atPath: paths.googleClient.path)
            publish { $0.state = missing ? .needsCredentials : .cannotStart("\(error)") }
            // With a menu bar the icon already says what is missing; a notification every
            // few hours is for the headless case.
            if !showsMenuBar { Notifier.post("Cannot start: \(error)", category: "startup", paths: paths) }
        }
    }

    private func schedulePolling(fireNow: Bool) {
        timer?.cancel()
        let poll = max(15, runtime?.config.googlePollSeconds ?? 60)
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Rescheduling after a rebuild must not add a second cycle right behind the one that caused it.
        t.schedule(deadline: fireNow ? .now() : .now() + .seconds(poll), repeating: .seconds(poll), leeway: .seconds(5))
        t.setEventHandler { self.cycle() }
        t.resume()
        timer = t
        Log.info("polling Google every \(poll)s")
    }

    private func appleChanged() {
        queue.async {
            let now = Date()
            let first = self.firstPendingChange ?? now
            self.firstPendingChange = first
            self.debounce?.cancel()
            // One save produces several notifications over about five seconds; wait for
            // them to settle, but never longer than maxDebounceWait after the first.
            let delay = min(self.debounceSeconds, max(0, self.maxDebounceWait - now.timeIntervalSince(first)))
            let work = DispatchWorkItem { self.cycle() }
            self.debounce = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cycle() {
        debounce?.cancel()
        debounce = nil
        firstPendingChange = nil
        startRuntime()
        guard let rt = runtime else { return }
        // With a menu bar, a missing sign-in is a state the icon shows, not an error to
        // report every minute. Headless, the cycle runs and raises the usual notification.
        if showsMenuBar && !FileManager.default.fileExists(atPath: paths.googleToken.path) {
            // Keep the reason of a failed attempt on screen instead of overwriting it every minute.
            var alreadyShown = false
            if case .needsGoogleAuthorization = status.state { alreadyShown = true }
            if !alreadyShown { publish { $0.state = .needsGoogleAuthorization(nil) } }
            return
        }
        let previous = status.state
        publish { $0.state = .syncing }
        let outcome = rt.lockedCycle(SyncEngine.Options())
        let links = (try? rt.store.allLinks()) ?? []
        publish {
            $0.pairedEvents = links.count
            $0.createdInGoogle = links.filter { $0.origin == .google }.count
            switch outcome {
            case .ok:
                $0.state = .idle
                $0.lastSuccess = Date()
            // Another process synced instead of us: that says nothing about our own state.
            case .busy: $0.state = previous
            case .blocked(let reason): $0.state = .paused(reason)
            case .needsGoogleAuthorization: $0.state = .needsGoogleAuthorization("the sign-in has expired or was revoked")
            case .noCalendarAccess: $0.state = .noCalendarAccess
            case .failed(let message): $0.state = .failed(message)
            }
        }
    }

    /// Change the status (cycle queue) and hand a copy to the menu bar (main thread).
    private func publish(_ change: (inout DaemonStatus) -> Void) {
        change(&status)
        let snapshot = status
        DispatchQueue.main.async { self.menuBar?.show(snapshot) }
    }
}

/// One browser sign-in. Shared between the thread that waits for the browser and the cycle
/// queue, which may cancel it.
private final class SignInAttempt {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
