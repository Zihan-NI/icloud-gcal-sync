import AppKit
import Foundation
import SyncCore
import UniformTypeIdentifiers

/// The menu bar icon: what the sync is doing, plus the few things a user needs to do by
/// hand (sync now, refresh, choose the Google credentials file, sign in). Main thread only.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let daemon: Daemon
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var status = DaemonStatus()
    private var isOpen = false
    private weak var headlineItem: NSMenuItem?

    init(daemon: Daemon) {
        self.daemon = daemon
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        show(status)
    }

    func show(_ status: DaemonStatus) {
        self.status = status
        let symbol: String
        switch status.state {
        case .syncing, .starting: symbol = "arrow.triangle.2.circlepath"
        case .idle: symbol = status.signingIn ? "arrow.triangle.2.circlepath" : "calendar"
        default: symbol = "calendar.badge.exclamationmark"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iCloud ⇄ Google calendar sync")
        image?.isTemplate = true   // follows the menu bar's light or dark appearance
        item.button?.image = image
        item.button?.toolTip = headline
        // Replacing the items of a menu the user is pointing at would drop their click.
        // While it is open only the first line follows the state; the rest is rebuilt the
        // next time it opens.
        if isOpen { headlineItem?.title = shortened(headline) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    private var headline: String {
        switch status.state {
        case .starting: return "Starting…"
        case .needsCredentials: return "Google is not set up: choose the credentials file"
        case .cannotStart(let why): return "Cannot start: \(why)"
        case .needsGoogleAuthorization: return "Not signed in to Google"
        case .noCalendarAccess: return "No access to Apple Calendar"
        case .syncing: return "Syncing…"
        case .idle: return "Up to date"
        case .paused(let reason): return "Paused: \(reason)"
        case .failed(let message): return "Last sync failed: \(message)"
        }
    }

    /// Long reasons would make the menu as wide as the screen.
    private func shortened(_ text: String) -> String {
        text.count > 90 ? String(text.prefix(88)) + "…" : text
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func info(_ text: String) -> NSMenuItem {
            let shown = shortened(text)
            let i = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
            i.isEnabled = false
            if shown != text { i.toolTip = text }
            menu.addItem(i)
            return i
        }
        func action(_ title: String, _ selector: Selector, key: String = "", enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            i.target = self
            i.isEnabled = enabled
            menu.addItem(i)
        }

        var syncing = false, signedOut = false, hasCredentials = true, canSync = true
        switch status.state {
        case .syncing, .starting: syncing = true
        case .needsGoogleAuthorization: signedOut = true; canSync = false
        case .needsCredentials: hasCredentials = false; canSync = false
        case .cannotStart: canSync = false
        default: break
        }

        // Status
        headlineItem = info(headline)
        if case .needsGoogleAuthorization(let reason?) = status.state { info("Last attempt: \(reason)") }
        if case .noCalendarAccess = status.state { info("Allow it in System Settings → Privacy & Security → Calendars") }
        if case .paused = status.state { info("To apply it anyway run: icloud-gcal-sync sync --allow-mass-delete") }
        if let last = status.lastSuccess {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            let ago = Date().timeIntervalSince(last) < 5 ? "just now" : f.localizedString(for: last, relativeTo: Date())
            info("Last synced \(ago)")
        }
        if !status.googleCalendarName.isEmpty {
            info("\(status.pairedEvents) events in sync, \(status.createdInGoogle) created in Google")
            info("Google “\(status.googleCalendarName)” ⇄ iCloud; new Google events go to “\(status.appleTargetCalendar)”")
        }
        menu.addItem(.separator())

        // Actions
        action("Sync Now", #selector(syncNow), key: "s", enabled: canSync && !syncing)
        action("Refresh", #selector(refresh), key: "r", enabled: !syncing)
        menu.addItem(.separator())
        action("Choose Google Credentials (JSON)…", #selector(chooseCredentials))
        if status.signingIn {
            info("Waiting for the Google sign-in in your browser…")
            action("Cancel Sign-In", #selector(cancelSignIn))
        } else if hasCredentials {
            action(signedOut ? "Sign In to Google…" : "Switch Google Account…", #selector(signIn))
        }
        action("Open Log", #selector(openLog))
    }

    // MARK: - Actions

    @objc private func syncNow() { daemon.syncNow() }
    @objc private func refresh() { daemon.refresh() }
    @objc private func cancelSignIn() { daemon.cancelSignIn() }

    @objc private func signIn() {
        if case .needsGoogleAuthorization = status.state {
            daemon.signInToGoogle()
            return
        }
        // Signing in again while everything works means changing accounts; say what that does.
        let alert = NSAlert()
        alert.messageText = "Sign in with a different Google account?"
        alert.informativeText = "A new “\(status.googleCalendarName)” calendar is created in the account you sign in with, and your Apple events are copied to it again. "
            + "The calendar in the current account is left as it is; delete it in Google Calendar if you no longer want it.\n\nYour Apple events are not changed."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { daemon.signInToGoogle() }
    }

    @objc private func chooseCredentials() {
        let panel = NSOpenPanel()
        panel.title = "Choose the OAuth client file from Google Cloud Console"
        panel.message = "The JSON file downloaded for a “Desktop app” OAuth client (usually named client_secret_….json)."
        panel.prompt = "Use This File"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        // A menu bar process is never frontmost by itself; without this the panel opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = daemon.useCredentials(from: url) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That file cannot be used"
            alert.informativeText = problem
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(daemon.paths.logFile)
    }
}
