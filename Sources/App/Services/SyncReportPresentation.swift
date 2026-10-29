import Foundation
import SharedDomain

/// One policy for timestamps, notifications and the status shown after a sync.
struct SyncReportPresentation {
    let report: SyncRunReport

    var shouldNotifyCompletion: Bool { report.allSucceeded }
    func lastSuccessfulSync(previous: Date?) -> Date? { report.successfulCompletionDate ?? previous }

    var message: String? {
        guard !report.isNoOp, !report.allSucceeded else { return nil }
        let noun = report.courses.count == 1 ? "course" : "courses"
        let updated = "\(report.succeededCount) of \(report.courses.count) \(noun) updated."
        if report.requiresReauthentication { return "\(updated) Sign in again to finish syncing." }
        if report.wasCancelled { return "Sync cancelled. \(updated)" }
        var details: [String] = []
        if report.failedCount > 0 { details.append("\(report.failedCount) failed") }
        if report.incompleteCount > 0 { details.append("\(report.incompleteCount) incomplete") }
        if report.skippedCount > 0 { details.append("\(report.skippedCount) skipped") }
        if report.cancelledCount > 0 { details.append("\(report.cancelledCount) cancelled") }
        if details.isEmpty { return "\(updated) Some files could not finish syncing. Try again." }
        return "\(updated) \(details.joined(separator: ", ")). Try again."
    }
}

/// Persist one safe snapshot per site in the app's injected, channel-specific defaults.
@MainActor
struct SyncReportStore {
    struct Snapshot: Codable, Equatable {
        let report: SyncRunReport
        let lastSuccessfulSync: Date?
    }

    let defaults: UserDefaults
    private func key(_ siteID: String) -> String { "syncReport.\(siteID)" }

    func load(siteID: String) -> Snapshot? {
        guard let data = defaults.data(forKey: key(siteID)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.report.siteID == siteID else { return nil }
        return snapshot
    }

    @discardableResult
    func save(_ report: SyncRunReport, previousSuccess: Date?) -> Snapshot {
        let snapshot = Snapshot(report: report, lastSuccessfulSync: report.successfulCompletionDate ?? previousSuccess)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key(report.siteID)) }
        return snapshot
    }

    func remove(siteID: String) { defaults.removeObject(forKey: key(siteID)) }
}
