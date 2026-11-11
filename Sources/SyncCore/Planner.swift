import Foundation

/// One thing the engine will do. Produced by `Planner`, executed by `SyncEngine`.
public enum SyncAction: Equatable, Sendable {
    /// New Apple event: create its mirror copy in Google.
    case createGoogle(apple: AppleCalEvent)
    /// A marked Google copy exists but the link was lost (database deleted, or the copy was
    /// written by the Python version): pair them again instead of deleting and recreating.
    case adopt(apple: AppleCalEvent, google: GoogleEvent)
    case updateGoogle(link: Link, apple: AppleCalEvent)
    /// The Google copy disappeared but the Apple event should keep one.
    case recreateGoogle(link: Link, apple: AppleCalEvent)
    /// `link` is nil for an orphaned mirror copy that no longer has an Apple original.
    case deleteGoogle(link: Link?, googleID: String)
    /// New event created in Google: create it in the Apple target calendar.
    case createApple(google: GoogleEvent)
    /// `apple` is the event as it is now, so the write goes to its current local identifier
    /// even if that changed since the link was stored.
    case updateApple(link: Link, google: GoogleEvent, apple: AppleCalEvent)
    /// The Apple event disappeared but the Google event was edited since: bring it back.
    case recreateApple(link: Link, google: GoogleEvent)
    case deleteApple(link: Link, apple: AppleCalEvent)
    /// An unmarked Google event and an unlinked Apple event with identical content: the two
    /// halves of a pair whose link was lost (database deleted, or a crash between creating
    /// the Apple copy and recording it). Pair them again instead of duplicating both.
    case pair(apple: AppleCalEvent, google: GoogleEvent)
    /// Both sides changed to the same content: just remember the new state.
    case refreshBaselines(link: Link, apple: AppleCalEvent, google: GoogleEvent)
    /// Forget the pairing without touching either calendar.
    case dropLink(link: Link)

    public var deletesGoogle: Bool { if case .deleteGoogle = self { return true }; return false }
    public var deletesApple: Bool { if case .deleteApple = self { return true }; return false }
    public var createsGoogle: Bool {
        switch self {
        case .createGoogle, .recreateGoogle: return true
        default: return false
        }
    }
    /// Does this action change either calendar (as opposed to local bookkeeping only)?
    public var writesCalendar: Bool {
        switch self {
        case .refreshBaselines, .dropLink, .pair: return false
        case .adopt(let a, let g): return a.content.contentHash != g.content?.contentHash || g.mirrorKey != a.key
        default: return true
        }
    }
}

public struct Plan: Equatable, Sendable {
    public var actions: [SyncAction] = []
    /// Events created in Google that are recurring. Not synced back in this version.
    public var skippedRecurringGoogle = 0
    /// Two-way events edited on both sides between runs, and which side won.
    public var conflicts: [String] = []

    public func count(_ predicate: (SyncAction) -> Bool) -> Int { actions.filter(predicate).count }

    public var summary: String {
        var n: [String: Int] = [:]
        for a in actions {
            let k: String
            switch a {
            case .createGoogle: k = "create→Google"
            case .adopt, .pair: k = "adopt"
            case .updateGoogle: k = "update→Google"
            case .recreateGoogle: k = "recreate→Google"
            case .deleteGoogle: k = "delete in Google"
            case .createApple: k = "create→Apple"
            case .updateApple: k = "update→Apple"
            case .recreateApple: k = "recreate→Apple"
            case .deleteApple: k = "delete in Apple"
            case .refreshBaselines: k = "refresh"
            case .dropLink: k = "forget"
            }
            n[k, default: 0] += 1
        }
        if n.isEmpty { return "nothing to do" }
        return n.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }
}

/// Decides what has to happen, from a consistent picture of both sides. Pure: no I/O.
///
/// Change detection never compares the two sides with each other. Each link remembers a
/// hash per side; a side has "changed" only when its current hash differs from its own
/// baseline. That is what stops our own writes from echoing back as edits, and it stays
/// correct even when the two services store the same event slightly differently.
public enum Planner {
    /// - Parameters:
    ///   - apple: the window snapshot, plus any linked single events found by direct lookup
    ///     outside the window.
    ///   - lookedUp: keys of links whose Apple event was looked up directly, so that absence
    ///     from `apple` means it really is gone and not merely outside the window.
    ///   - google: the complete current contents of the mirror calendar.
    public static func plan(apple: [AppleCalEvent], lookedUp: Set<String> = [], google: [GoogleEvent], links: [Link],
                            window: DateInterval, policy: SyncConfig.ConflictPolicy = .newest,
                            timeZone: TimeZone = .current) -> Plan {
        var plan = Plan()
        var writes: [SyncAction] = [], deletes: [SyncAction] = [], bookkeeping: [SyncAction] = []

        var appleByKey: [String: AppleCalEvent] = [:]
        for a in apple where appleByKey[a.key] == nil { appleByKey[a.key] = a }
        var googleByID: [String: GoogleEvent] = [:]
        for g in google where !g.isCancelled { googleByID[g.id] = g }

        func inWindow(_ instant: Date) -> Bool { window.start <= instant && instant < window.end }

        var linkedAppleKeys = Set<String>(), linkedGoogleIDs = Set<String>()
        for link in links {
            linkedAppleKeys.insert(link.appleKey)
            linkedGoogleIDs.insert(link.googleEventID)
            let a = appleByKey[link.appleKey]
            let g = googleByID[link.googleEventID]
            let linkStart = Date(timeIntervalSince1970: link.startTS)

            switch (a, g) {
            case (nil, nil):
                bookkeeping.append(.dropLink(link: link))

            case (let a?, let g?):
                guard let gContent = g.content else { continue }
                let aHash = a.content.contentHash, gHash = gContent.contentHash
                let aChanged = aHash != link.appleHash, gChanged = gHash != link.googleHash
                if !aChanged && !gChanged { continue }
                if aHash == gHash {
                    bookkeeping.append(.refreshBaselines(link: link, apple: a, google: g))
                    continue
                }
                let twoWay = link.mode == .twoWay && a.syncsBothWays && !g.isRecurring
                if aChanged && !gChanged {
                    writes.append(.updateGoogle(link: link, apple: a))
                } else if gChanged && !aChanged {
                    // An edit to a one-way mirror copy is left in place until the Apple
                    // original changes, as the Python version did.
                    if twoWay { writes.append(.updateApple(link: link, google: g, apple: a)) }
                } else if !twoWay {
                    writes.append(.updateGoogle(link: link, apple: a))
                } else {
                    var googleWins = false
                    if policy == .newest, let am = a.lastModified, let gm = g.updated { googleWins = gm > am }
                    plan.conflicts.append("\"\(a.content.normalized.title)\": edited on both sides, \(googleWins ? "Google" : "Apple") copy kept")
                    writes.append(googleWins ? .updateApple(link: link, google: g, apple: a) : .updateGoogle(link: link, apple: a))
                }

            case (let a?, nil):
                // The Google copy is gone.
                let twoWay = link.mode == .twoWay && a.syncsBothWays
                let aChanged = a.content.contentHash != link.appleHash
                if twoWay && !aChanged {
                    deletes.append(.deleteApple(link: link, apple: a))
                } else {
                    // A mirror copy is always restored; an edit beats a delete.
                    writes.append(.recreateGoogle(link: link, apple: a))
                }

            case (nil, let g?):
                // The Apple event is not in the snapshot.
                if linkStart < window.start {
                    // It has scrolled out of the window: the copy stays as history.
                    bookkeeping.append(.dropLink(link: link))
                } else if inWindow(linkStart) || lookedUp.contains(link.appleKey) {
                    let gChanged = g.content.map { $0.contentHash != link.googleHash } ?? false
                    if link.mode == .twoWay && gChanged && !g.isRecurring {
                        writes.append(.recreateApple(link: link, google: g))
                    } else {
                        deletes.append(.deleteGoogle(link: link, googleID: g.id))
                    }
                } else {
                    // Beyond the end of the window and never looked up: we cannot tell
                    // whether it was deleted, so leave the copy alone.
                    bookkeeping.append(.dropLink(link: link))
                }
            }
        }

        // Unlinked events on either side.
        var unlinkedApple = apple.filter { !linkedAppleKeys.contains($0.key) && inWindow($0.content.timing.startInstant(in: timeZone)) }
        var seenKeys = Set<String>()
        unlinkedApple = unlinkedApple.filter { seenKeys.insert($0.key).inserted }
        let unlinkedGoogle = googleByID.values.filter { !linkedGoogleIDs.contains($0.id) && $0.content != nil }
            .sorted { $0.id < $1.id }

        var adoptedApple = Set<String>(), adoptedGoogle = Set<String>()
        let marked = unlinkedGoogle.filter { $0.mirrorKey != nil }

        // 1. Exact key match.
        var markedByKey: [String: [GoogleEvent]] = [:]
        for g in marked { markedByKey[g.mirrorKey!, default: []].append(g) }
        for a in unlinkedApple {
            if let g = markedByKey[a.key]?.first(where: { !adoptedGoogle.contains($0.id) }) {
                writes.append(.adopt(apple: a, google: g))
                adoptedApple.insert(a.key); adoptedGoogle.insert(g.id)
            }
        }
        // 2. Copies written by the Python version carry "<calendar hash>|<UID>[|<recurrence id>]".
        //    The calendar part cannot be reproduced from EventKit, so match on the rest, and
        //    only when that is unambiguous.
        var appleByUID: [String: [AppleCalEvent]] = [:]
        for a in unlinkedApple where !adoptedApple.contains(a.key) {
            appleByUID[legacyID(uid: a.externalID, occurrence: a.occurrence), default: []].append(a)
        }
        for g in marked where !adoptedGoogle.contains(g.id) {
            let parts = g.mirrorKey!.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let id = legacyID(uid: parts[1], occurrence: parts.count > 2 ? parts[2] : nil)
            let candidates = (appleByUID[id] ?? []).filter { !adoptedApple.contains($0.key) }
            if candidates.count == 1 {
                writes.append(.adopt(apple: candidates[0], google: g))
                adoptedApple.insert(candidates[0].key); adoptedGoogle.insert(g.id)
            }
        }

        // 3. Pairs whose link was lost and that carry no marker (events created in Google):
        //    identical content on both sides, and only when the match is unique.
        let unmarked = unlinkedGoogle.filter { $0.mirrorKey == nil && !$0.isRecurring }
        var appleByHash: [String: [AppleCalEvent]] = [:], googleByHash: [String: [GoogleEvent]] = [:]
        for a in unlinkedApple where !adoptedApple.contains(a.key) && a.syncsBothWays {
            appleByHash[a.content.contentHash, default: []].append(a)
        }
        for g in unmarked { googleByHash[g.content!.contentHash, default: []].append(g) }
        for (hash, gs) in googleByHash.sorted(by: { $0.key < $1.key }) where gs.count == 1 {
            guard let candidates = appleByHash[hash], candidates.count == 1 else { continue }
            bookkeeping.append(.pair(apple: candidates[0], google: gs[0]))
            adoptedApple.insert(candidates[0].key); adoptedGoogle.insert(gs[0].id)
        }

        for a in unlinkedApple where !adoptedApple.contains(a.key) {
            writes.append(.createGoogle(apple: a))
        }
        for g in unlinkedGoogle where !adoptedGoogle.contains(g.id) {
            let start = g.content!.timing.startInstant(in: timeZone)
            if g.mirrorKey != nil {
                // A mirror copy whose Apple original no longer exists.
                if inWindow(start) { deletes.append(.deleteGoogle(link: nil, googleID: g.id)) }
            } else if g.isRecurring {
                plan.skippedRecurringGoogle += 1
            } else if inWindow(start) {
                writes.append(.createApple(google: g))
            }
        }

        // Deletions last: if a run dies half way, nothing has been lost yet.
        plan.actions = writes + bookkeeping + deletes
        return plan
    }

    private static func legacyID(uid: String, occurrence: String?) -> String {
        "\(uid)\u{1F}\(occurrence ?? "")"
    }
}
