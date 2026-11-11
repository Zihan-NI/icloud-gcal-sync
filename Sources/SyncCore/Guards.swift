import Foundation

private let emptySideLimit = 3

/// Refuses to apply a plan that looks like the result of bad input rather than of the
/// user's intent. Returns the reason, or nil when the plan may proceed.
///
/// The danger on the Apple→Google side is EventKit suddenly returning far fewer events
/// (an account signed out, a calendar vanished). Re-keyed events (editing "all future
/// events" of a series) show up as deletes plus creates without shrinking the Apple count,
/// so the count is compared with the last successful run's; the per-run net count is only
/// a fallback when there is no history.
///
/// The Google→Apple side is stricter, because there the tool deletes the user's originals:
/// any run that would delete more than a handful of Apple events is stopped.
public func deletionGuard(plan: Plan, appleCount: Int, googleCount: Int, previousAppleCount: Int?,
                          config: SyncConfig) -> String? {
    let googleDeletes = plan.count { $0.deletesGoogle }
    let appleDeletes = plan.count { $0.deletesApple }

    if appleDeletes > config.maxAppleDeletesPerRun {
        return "\(appleDeletes) Apple events would be deleted because their Google copies are gone "
            + "(limit max_apple_deletes_per_run=\(config.maxAppleDeletesPerRun))"
    }
    // One side coming back completely empty is the signature of a bad read. A handful of
    // deletions is still allowed, or deleting the only event in a calendar would be refused.
    if googleCount == 0 && appleDeletes > emptySideLimit {
        return "the Google calendar came back empty but \(appleDeletes) Apple events would be deleted"
    }
    if appleCount == 0 && googleDeletes > emptySideLimit {
        return "Apple Calendar returned 0 events but \(googleDeletes) Google copies would be deleted"
    }
    if let previous = previousAppleCount {
        let drop = previous - appleCount
        if drop > config.maxDeletesPerRun && googleDeletes > config.maxDeletesPerRun {
            return "Apple Calendar now has \(appleCount) events vs \(previous) last run "
                + "(drop of \(drop) > max_deletes_per_run=\(config.maxDeletesPerRun))"
        }
        return nil
    }
    let net = googleDeletes - plan.count { $0.createsGoogle }
    if net > config.maxDeletesPerRun {
        return "net deletion of \(net) Google copies exceeds max_deletes_per_run=\(config.maxDeletesPerRun)"
    }
    return nil
}
