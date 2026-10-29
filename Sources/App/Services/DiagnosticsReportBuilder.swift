import Foundation
import SharedDomain
import FindlePersistence
@preconcurrency import FileProvider

@MainActor
enum DiagnosticsReportBuilder {
    struct Input: Sendable {
        var appVersion: String
        var appBuild: String
        var revision: String?
        var channel: String
        var databasePath: String?
        var additionalDatabasePaths: [String] = []
        var databaseFailure: DiagnosticFailure?
        var siteID: String?
        var syncState: String
        var lastSuccessfulSync: Date?
        var syncAttemptID: UUID?
        var courses: [DiagnosticCourseOutcome]
    }

    static func capture(
        _ input: Input,
        providerTimeout: Duration = .seconds(3),
        providerProbe: (@MainActor @Sendable () async -> DiagnosticProviderSnapshot)? = nil
    ) async -> StabilityDiagnosticReport {
        let storage = Task.detached(priority: .utility) {
            var database = DatabaseDiagnostics.capture(path: input.databasePath, siteID: input.siteID)
            if database.schemaVersion == nil, database.failure == nil, let failure = input.databaseFailure {
                database = DiagnosticDatabaseSnapshot(failure: failure)
            }
            var events: [DiagnosticEvent] = []
            var failure: DiagnosticFailure?
            let paths = Set(input.additionalDatabasePaths + [input.databasePath].compactMap { $0 })
            for path in paths.sorted() {
                if let journal = DiagnosticJournal(databasePath: path) {
                    do { events.append(contentsOf: try journal.read()) } catch { failure = DiagnosticFailure(error) }
                }
            }
            var seen = Set<UUID>()
            events = events.filter { seen.insert($0.id).inserted }.sorted { $0.timestamp < $1.timestamp }
            return (database, events, failure)
        }
        let provider = await probeWithDeadline(timeout: providerTimeout) {
            if let providerProbe { return await providerProbe() }
            guard let siteID = input.siteID else { return DiagnosticProviderSnapshot(state: .notRegistered) }
            do {
                let domains = try await NSFileProviderManager.domains()
                let id = BundleIdentifiers.fileProviderDomainID(siteID: siteID)
                let registered = domains.contains { $0.identifier.rawValue == id }
                return DiagnosticProviderSnapshot(state: registered ? .registered : .notRegistered)
            } catch { return DiagnosticProviderSnapshot(state: .unavailable, failure: DiagnosticFailure(error)) }
        }
        let (database, events, journalFailure) = await storage.value
        return StabilityDiagnosticReport(
            appVersion: input.appVersion, appBuild: input.appBuild, revision: input.revision, channel: input.channel,
            syncState: input.syncState, lastSuccessfulSync: input.lastSuccessfulSync, syncAttemptID: input.syncAttemptID,
            courses: input.courses, database: database, provider: provider, events: events, journalFailure: journalFailure
        )
    }

    /// File Provider's XPC call may not honor task cancellation. Racing through a
    /// stream lets export finish at the deadline without waiting for that reply.
    private static func probeWithDeadline(
        timeout: Duration,
        probe: @escaping @MainActor @Sendable () async -> DiagnosticProviderSnapshot
    ) async -> DiagnosticProviderSnapshot {
        let (stream, continuation) = AsyncStream<DiagnosticProviderSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let query = Task { @MainActor in continuation.yield(await probe()); continuation.finish() }
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(DiagnosticProviderSnapshot(state: .timedOut))
                continuation.finish()
            } catch { }
        }
        defer { query.cancel(); deadline.cancel(); continuation.finish() }
        for await result in stream { return result }
        return DiagnosticProviderSnapshot(state: .unavailable, failure: DiagnosticFailure(CancellationError()))
    }
}
