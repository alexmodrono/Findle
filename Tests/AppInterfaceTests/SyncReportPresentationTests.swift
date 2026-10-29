import Foundation
import Testing
import SharedDomain

struct SyncReportPresentationTests {
    private let previous = Date(timeIntervalSince1970: 100)
    private let finished = Date(timeIntervalSince1970: 200)

    private func presentation(_ outcomes: [SyncCourseOutcome.Outcome], cancelled: Bool = false) -> SyncReportPresentation {
        SyncReportPresentation(report: SyncRunReport(
            siteID: "site", startedAt: previous, finishedAt: finished,
            courses: outcomes.enumerated().map { SyncCourseOutcome(courseID: $0.offset, outcome: $0.element) },
            wasCancelled: cancelled
        ))
    }

    @Test func partialRunKeepsPreviousSuccessAndSuppressesCompletionNotification() {
        let value = presentation([.succeeded, .failed, .incomplete, .skipped])
        #expect(value.lastSuccessfulSync(previous: previous) == previous)
        #expect(!value.shouldNotifyCompletion)
        #expect(value.message == "1 of 4 courses updated. 1 failed, 1 incomplete, 1 skipped. Try again.")
    }

    @Test func emptySelectionIsANoOp() {
        let value = presentation([])
        #expect(value.report.isNoOp)
        #expect(!value.shouldNotifyCompletion)
        #expect(value.lastSuccessfulSync(previous: nil) == nil)
        #expect(value.message == nil)
    }

    @Test func cancellationCannotTurnCommittedCoursesIntoFullSuccess() {
        let value = presentation([.succeeded, .cancelled, .skipped], cancelled: true)
        #expect(!value.shouldNotifyCompletion)
        #expect(value.lastSuccessfulSync(previous: previous) == previous)
        #expect(value.message == "Sync cancelled. 1 of 3 courses updated.")
    }

    @Test func fullRecoveryAdvancesSuccessAndEnablesNotification() {
        let value = presentation([.succeeded, .succeeded])
        #expect(value.shouldNotifyCompletion)
        #expect(value.lastSuccessfulSync(previous: previous) == finished)
        #expect(value.message == nil)
    }
}

struct SyncReportStoreTests {
    @Test @MainActor func relaunchRestoresPartialOutcomesAndPreviousSuccessWithoutCrossingSites() throws {
        let suite = "SyncReportStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncReportStore(defaults: defaults)
        let earlier = Date(timeIntervalSince1970: 100)
        let success = SyncRunReport(siteID: "site-a", startedAt: earlier, finishedAt: earlier,
                                    courses: [SyncCourseOutcome(courseID: 1, outcome: .succeeded)])
        store.save(success, previousSuccess: nil)
        let partial = SyncRunReport(siteID: "site-a", startedAt: Date(timeIntervalSince1970: 200),
                                    courses: [SyncCourseOutcome(courseID: 1, outcome: .failed,
                                                                lastSuccessfulSync: earlier,
                                                                failure: DiagnosticFailure(FindleError.networkUnavailable))])
        store.save(partial, previousSuccess: earlier)
        let relaunched = SyncReportStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let snapshot = try #require(relaunched.load(siteID: "site-a"))
        #expect(snapshot.report == partial)
        #expect(snapshot.lastSuccessfulSync == earlier)
        #expect(!SyncReportPresentation(report: snapshot.report).shouldNotifyCompletion)
        #expect(relaunched.load(siteID: "site-b") == nil)
        relaunched.remove(siteID: "site-a")
        #expect(store.load(siteID: "site-a") == nil)
    }
}
