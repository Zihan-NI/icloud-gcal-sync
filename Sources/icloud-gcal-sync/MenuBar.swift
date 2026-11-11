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
    private var presentingGuide = false
    /// Guides already offered since launch, so a marker file that cannot be written does
    /// not make a guide reappear on every status update.
    private var offered: Set<String> = []
    static let readmeURL = URL(string: "https://github.com/Zihan-NI/icloud-gcal-sync#readme")!

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
        offerGuideIfDue()
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
        menu.addItem(.separator())
        if !hasCredentials { action("Setup Guide…", #selector(showSetupGuide)) }
        action("How It Works…", #selector(showHowItWorks))
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

    // MARK: - Guides

    /// Each guide opens by itself once: the setup steps when Google is not set up yet, and
    /// the rules of the road after the first successful sync. Both stay available in the menu.
    private enum Guide: String { case setup = ".setup_guide_shown", howItWorks = ".how_it_works_shown" }

    private func offerGuideIfDue() {
        // Never on top of the menu, another dialog, or a sign-in that is waiting for the browser.
        guard !presentingGuide, !isOpen, !status.signingIn, NSApp.modalWindow == nil else { return }
        let due: Guide
        switch status.state {
        case .needsCredentials: due = .setup
        case .idle where status.lastSuccess != nil: due = .howItWorks
        default: return
        }
        let marker = daemon.paths.root.appendingPathComponent(due.rawValue)
        guard !offered.contains(due.rawValue), !FileManager.default.fileExists(atPath: marker.path) else { return }
        offered.insert(due.rawValue)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        // Not from inside show(): a modal alert must not run while the status is being delivered.
        DispatchQueue.main.async { due == .setup ? self.showSetupGuide() : self.showHowItWorks() }
    }

    @objc private func showSetupGuide() {
        guard !presentingGuide else { return }
        presentingGuide = true
        defer { presentingGuide = false }
        let alert = NSAlert()
        alert.messageText = "Set up Google Calendar access"
        alert.informativeText = """
            The sync talks to Google through an OAuth client that you create in your own Google Cloud project, so your calendar data goes to nobody else. You do this once.

            1. In Google Cloud Console, create a project and enable the Google Calendar API.
            2. Under Google Auth Platform, choose External and publish the app (or Internal, if you use Google Workspace).
            3. Under Clients, create a client of type “Desktop app” and download its JSON file.
            4. Click “Choose File…” below and pick that file. Your browser then opens for the Google sign-in.

            “Open Step-by-Step Guide” shows the README, which has a link for each step.
            """
        alert.addButton(withTitle: "Choose File…")
        alert.addButton(withTitle: "Open Step-by-Step Guide")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: chooseCredentials()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(MenuBarController.readmeURL)
        default: break
        }
    }

    @objc private func showHowItWorks() {
        guard !presentingGuide else { return }
        presentingGuide = true
        defer { presentingGuide = false }
        let google = status.googleCalendarName.isEmpty ? "iCloud Sync" : status.googleCalendarName
        let target = status.appleTargetCalendar.isEmpty ? "From Google" : status.appleTargetCalendar
        let alert = NSAlert()
        alert.messageText = "How syncing works"
        alert.informativeText = """
            • Events in your iCloud calendars are copied to the Google calendar “\(google)” within seconds.

            • Events created in “\(google)”, by you or by an AI assistant, are copied to the iCloud calendar “\(target)” within about a minute. Events in your other Google calendars, including the main one, are not synced.

            • Editing or deleting a single event on either side changes the other side too: deleting it in Google deletes it in iCloud. Repeating events only go from iCloud to Google.

            • If your Google account is also added to Apple Calendar, uncheck “\(google)” in Calendar’s sidebar. Otherwise every event shows twice.

            • Syncing runs while this Mac is awake, and catches up after sleep.

            You can open this again from the menu bar icon.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open README")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(MenuBarController.readmeURL) }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(daemon.paths.logFile)
    }
}
