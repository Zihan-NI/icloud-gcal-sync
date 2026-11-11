import AppleCalendar
import Foundation
import SyncCore

/// Long-running mode: sync when Apple Calendar reports a change, and poll Google on a timer.
///
/// Both triggers run the same full cycle. Reading Apple Calendar is local and reading Google
/// is incremental, so a cycle with nothing to do costs one small request.
final class Daemon {
    private let paths: AppPaths
    private var runtime: Runtime?
    private let queue = DispatchQueue(label: "icloud-gcal-sync.cycle")
    private var debounce: DispatchWorkItem?
    private var firstPendingChange: Date?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var debounceSeconds = 5.0
    /// A burst of change notifications must not postpone the sync forever.
    private let maxDebounceWait = 30.0

    init(paths: AppPaths) { self.paths = paths }

    func run() -> Never {
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
        queue.async {
            self.startRuntime()
            if EventKitStore.access == .notDetermined, let rt = self.runtime {
                Log.info("asking for calendar access; answer the macOS prompt")
                _ = rt.apple.requestAccess()
            }
            self.schedulePolling()
        }
        // A real run loop, not dispatchMain(): EventKit delivers its change notifications
        // through run-loop sources, and without one EKEventStoreChanged never arrives.
        while true { RunLoop.main.run(until: .distantFuture) }
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
            if timer != nil { schedulePolling() }
        } catch {
            Log.error("cannot start: \(error)")
            Notifier.post("Cannot start: \(error)", category: "startup", paths: paths)
        }
    }

    private func schedulePolling() {
        timer?.cancel()
        let poll = max(15, runtime?.config.googlePollSeconds ?? 60)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(poll), leeway: .seconds(5))
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
        runtime?.lockedCycle(SyncEngine.Options())
    }
}
