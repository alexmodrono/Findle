import Foundation
import SharedDomain

/// Keeps destructive provider operations behind a verified, bound fallback.
/// Session writer draining and resumption belong to the AppState transition lease.
@MainActor
struct ProviderResetCoordinator<Handle: Sendable> {
    enum Stage: String, Sendable, CaseIterable { case prepareFallback, removeDomain, addDomain, seedDatabase }

    struct Failure: Error, LocalizedError {
        let stage: Stage
        let underlying: any Error

        var errorDescription: String? {
            switch stage {
            case .prepareFallback:
                "Finder was not reset because a complete recovery copy could not be prepared. Your current data was kept."
            case .removeDomain:
                "Finder could not be removed. Your recovery copy is ready. Try Reset Finder again."
            case .addDomain:
                "Finder could not be added again. Your data is in the recovery copy. Try Reset Finder again."
            case .seedDatabase:
                "Finder could not restore its index. Your data is in the recovery copy. Try Reset Finder again."
            }
        }
    }

    struct Operations {
        var prepareFallback: @MainActor () async throws -> Handle
        var bind: @MainActor (Handle) -> Void
        var removeDomain: @MainActor () async throws -> Void
        var addDomain: @MainActor () async throws -> Void
        var seedDatabase: @MainActor (Handle) async throws -> Handle
    }

    let operations: Operations

    func run(attemptID: UUID = UUID(), record: (DiagnosticEvent) -> Void) async throws {
        var stage = Stage.prepareFallback
        record(.init(attemptID: attemptID, process: .app, operation: .providerReset, outcome: .started))
        do {
            try Task.checkCancellation()
            let fallback = try await operations.prepareFallback()
            try Task.checkCancellation()
            operations.bind(fallback)
            stage = .removeDomain
            try await operations.removeDomain()
            try Task.checkCancellation()
            stage = .addDomain
            try await operations.addDomain()
            try Task.checkCancellation()
            stage = .seedDatabase
            let restored = try await operations.seedDatabase(fallback)
            try Task.checkCancellation()
            operations.bind(restored)
            record(.init(attemptID: attemptID, process: .app, operation: .providerReset, outcome: .succeeded))
        } catch is CancellationError {
            record(.init(attemptID: attemptID, process: .app, operation: .providerReset, outcome: .cancelled))
            throw CancellationError()
        } catch {
            record(.init(attemptID: attemptID, process: .app, operation: .providerReset,
                         outcome: .failed, failure: DiagnosticFailure(error)))
            throw Failure(stage: stage, underlying: error)
        }
    }
}
