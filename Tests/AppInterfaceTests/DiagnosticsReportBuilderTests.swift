import Testing
import Foundation
import SharedDomain

@MainActor
struct DiagnosticsReportBuilderTests {
    @Test func exportRetainsBootstrapFailureAfterAdoptingAProviderDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = root.appendingPathComponent("bootstrap")
        let provider = root.appendingPathComponent("provider")
        for directory in [bootstrap, provider] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let attempt = UUID()
        #expect(DiagnosticJournal(directory: bootstrap).record(.init(
            attemptID: attempt, process: .app, operation: .providerRegistration, outcome: .failed,
            failure: DiagnosticFailure(NSError(domain: "NSFileProviderErrorDomain", code: -2005)))))
        #expect(DiagnosticJournal(directory: provider).record(.init(
            relatedAttemptID: attempt, process: .fileProvider, operation: .databaseOpen, outcome: .succeeded)))
        let providerPath = provider.appendingPathComponent("findle.db").path
        let input = DiagnosticsReportBuilder.Input(
            appVersion: "2.0.0", appBuild: "123", channel: "nightly", databasePath: providerPath,
            additionalDatabasePaths: [bootstrap.appendingPathComponent("findle.db").path, providerPath],
            syncState: "idle", courses: [])
        let report = await DiagnosticsReportBuilder.capture(input) { DiagnosticProviderSnapshot(state: .registered) }
        #expect(report.events.count == 2)
        #expect(report.events.contains { $0.attemptID == attempt && $0.failure?.code == -2005 })
        #expect(report.events.contains { $0.relatedAttemptID == attempt })
        #expect(!String(decoding: try report.encoded(), as: UTF8.self).contains(root.path))
    }

    @Test func unavailableServicesStillProduceSafeExportWithOriginalProviderCode() async throws {
        let input = DiagnosticsReportBuilder.Input(
            appVersion: "2.0.0", appBuild: "123", channel: "nightly", databasePath: "/missing/private/findle.db",
            siteID: "secret-site", syncState: "error(token=SECRET)", courses: [
                DiagnosticCourseOutcome(courseID: 42, outcome: "failed", failure: DiagnosticFailure(
                    FindleError.requestFailed(statusCode: 429, detail: "password=SECRET")))
            ])
        let report = await DiagnosticsReportBuilder.capture(input) {
            DiagnosticProviderSnapshot(state: .unavailable,
                                       failure: DiagnosticFailure(NSError(domain: "NSFileProviderErrorDomain", code: -2005,
                                                                          userInfo: [NSLocalizedDescriptionKey: "token=SECRET"])))
        }
        let text = String(decoding: try report.encoded(), as: UTF8.self)
        for forbidden in ["SECRET", "secret-site", "/missing", "password", "token="] { #expect(!text.contains(forbidden)) }
        #expect(report.database.failure != nil)
        #expect(report.provider.failure?.code == -2005)
        #expect(report.provider.state == .unavailable)
        #expect(report.syncState == "unknown")
        #expect(report.courses.first?.failure?.code == 429)
    }

    @Test func unresponsiveProviderCannotKeepExportWaitingForItsReply() async throws {
        let suspended = SuspendedProbe()
        let input = DiagnosticsReportBuilder.Input(appVersion: "2.0.0", appBuild: "123", channel: "nightly",
                                                  syncState: "idle", courses: [])
        let report = await DiagnosticsReportBuilder.capture(input, providerTimeout: .milliseconds(20)) {
            await suspended.wait()
            return DiagnosticProviderSnapshot(state: .registered)
        }
        #expect(report.provider.state == .timedOut)
        // The late reply can finish without altering or invalidating the exported report.
        suspended.resume()
        #expect(!((try report.encoded()).isEmpty))
    }

    @MainActor private final class SuspendedProbe {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func resume() { continuation?.resume(); continuation = nil }
    }
}
