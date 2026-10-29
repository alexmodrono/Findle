import Testing
import Foundation
import SharedDomain
@testable import FindlePersistence

@MainActor
struct ProviderResetCoordinatorTests {
    @Test func fallbackCannotAuthorizeRemovingADifferentProviderStore() async throws {
        for state in ["higher-counter", "metadata-only", "future-schema"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fallback = try Database(path: root.appendingPathComponent("fallback.db").path)
            let providerURL = root.appendingPathComponent("provider.db")
            let provider = try Database(path: providerURL.path)
            let site = MoodleSite(id: "site", displayName: "Keep provider state", baseURL: URL(string: "https://example.invalid")!)
            try provider.saveSite(site)
            if state == "higher-counter" {
                try provider.saveItems([LocalItem(id: "local-newer", siteID: site.id, courseID: 0, remoteID: 0, filename: "keep.txt", isLocal: true)])
            }
            if state == "future-schema" { try provider.execute("PRAGMA user_version = 999") }
            var removed = false
            var bound = false
            let coordinator = ProviderResetCoordinator<Database>(operations: .init(
                prepareFallback: {
                    try fallback.verifyProviderResetSource(at: providerURL)
                    return fallback
                },
                bind: { _ in bound = true },
                removeDomain: { removed = true },
                addDomain: {},
                seedDatabase: { $0 }
            ))
            do {
                try await coordinator.run { _ in }
                Issue.record("Reset accepted a separate \(state) provider store")
            } catch let failure as ProviderResetCoordinator<Database>.Failure {
                #expect(failure.stage == .prepareFallback)
                if state == "future-schema" { #expect(failure.underlying is UnsupportedDatabaseSchemaError) }
            }
            #expect(!bound && !removed)
            #expect(try provider.fetchSite(id: site.id) == site)
            #expect(try provider.fetchAllItems(siteID: site.id).count == (state == "higher-counter" ? 1 : 0))
        }
    }

    @Test func emptyUnseededProviderCanRetryResetFromFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = try Database(path: root.appendingPathComponent("fallback.db").path)
        let providerURL = root.appendingPathComponent("provider.db")
        let provider = try Database(path: providerURL.path)
        #expect(try !provider.isSeedComplete())
        var removed = false
        let coordinator = ProviderResetCoordinator<Database>(operations: .init(
            prepareFallback: {
                try fallback.verifyProviderResetSource(at: providerURL)
                return fallback
            },
            bind: { _ in },
            removeDomain: { removed = true },
            addDomain: {},
            seedDatabase: { $0 }
        ))
        try await coordinator.run { _ in }
        #expect(removed)
    }

    @Test func retiredHandleCannotAuthorizeRemovingReplacementAtSamePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providerURL = root.appendingPathComponent("provider.db")
        let retired = try Database(path: providerURL.path)
        try retired.execute("PRAGMA journal_mode = DELETE")
        try FileManager.default.moveItem(at: providerURL, to: root.appendingPathComponent("retired.db"))
        let replacement = try Database(path: providerURL.path)
        let site = MoodleSite(id: "replacement", displayName: "Keep replacement", baseURL: URL(string: "https://example.invalid")!)
        try replacement.saveSite(site)
        #expect(throws: (any Error).self) { try retired.verifyProviderResetSource(at: providerURL) }
        #expect(try replacement.fetchSite(id: site.id) == site)
    }

    @Test func unreadableProviderPathCannotBeTreatedAsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = try Database(path: root.appendingPathComponent("fallback.db").path)
        let providerDirectory = root.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        let providerURL = providerDirectory.appendingPathComponent("index.db")
        let provider = try Database(path: providerURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: providerDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: providerDirectory.path) }
        #expect(throws: (any Error).self) { try fallback.verifyProviderResetSource(at: providerURL) }
        withExtendedLifetime(provider) {}
    }

    @Test func resetBindsVerifiedFallbackBeforeRemovingDomain() async throws {
        let fixture = Fixture()
        try await fixture.run()
        #expect(fixture.actions == ["snapshot", "open-fallback", "verify-fallback", "bind:fallback", "remove", "add", "seed", "bind:provider"])
        #expect(fixture.bound == "provider")
        #expect(fixture.events.map(\.outcome) == [.started, .succeeded])
        #expect(Set(fixture.events.map(\.attemptID)).count == 1)
        #expect(fixture.resumed)
    }

    @Test func everyFailureKeepsLastUsableHandleAndResumesSession() async throws {
        for failedStage in ProviderResetCoordinator<String>.Stage.allCases {
            let fixture = Fixture(failedStage: failedStage)
            do {
                try await fixture.run()
                Issue.record("Expected reset failure at \(failedStage)")
            } catch let error as ProviderResetCoordinator<String>.Failure {
                #expect(error.stage == failedStage)
                #expect(error.errorDescription?.contains("recovery copy") == true)
            }
            #expect(fixture.resumed)
            #expect(fixture.bound == (failedStage == .prepareFallback ? "original" : "fallback"))
            if failedStage == .prepareFallback { #expect(!fixture.actions.contains("remove")) }
            if failedStage == .removeDomain { #expect(!fixture.actions.contains("add")) }
            if failedStage == .addDomain { #expect(!fixture.actions.contains("seed")) }
            #expect(fixture.events.map(\.outcome) == [.started, .failed])
            #expect(fixture.events.last?.failure?.code == -2005)
            #expect(!String(decoding: try JSONEncoder().encode(fixture.events), as: UTF8.self).contains("secret-path"))
        }
    }

    @Test func cancellationAfterRemovalKeepsFallbackAndDoesNotContinueDestructiveWork() async throws {
        let fixture = Fixture(cancelAfterRemoval: true)
        let task = Task { try await fixture.run() }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(fixture.bound == "fallback")
        #expect(!fixture.actions.contains("add"))
        #expect(fixture.events.map(\.outcome) == [.started, .cancelled])
        #expect(fixture.resumed)
    }

    @MainActor private final class Fixture {
        var actions: [String] = []
        var events: [DiagnosticEvent] = []
        var bound = "original"
        var resumed = false
        let failedStage: ProviderResetCoordinator<String>.Stage?
        let cancelAfterRemoval: Bool

        init(failedStage: ProviderResetCoordinator<String>.Stage? = nil, cancelAfterRemoval: Bool = false) {
            self.failedStage = failedStage
            self.cancelAfterRemoval = cancelAfterRemoval
        }

        func fail(_ stage: ProviderResetCoordinator<String>.Stage) throws {
            if failedStage == stage {
                throw NSError(domain: "NSFileProviderErrorDomain", code: -2005,
                              userInfo: [NSLocalizedDescriptionKey: "secret-path token=do-not-export"])
            }
        }

        func run() async throws {
            // The AppState entry point uses this same defer around its session
            // transition, including fallback preparation failures/cancellation.
            defer { resumed = true }
            let coordinator = ProviderResetCoordinator<String>(operations: .init(
                prepareFallback: {
                    self.actions.append("snapshot")
                    self.actions.append("open-fallback")
                    try self.fail(.prepareFallback)
                    self.actions.append("verify-fallback")
                    return "fallback"
                },
                bind: { self.actions.append("bind:\($0)"); self.bound = $0 },
                removeDomain: {
                    self.actions.append("remove")
                    try self.fail(.removeDomain)
                    if self.cancelAfterRemoval { withUnsafeCurrentTask { $0?.cancel() } }
                },
                addDomain: { self.actions.append("add"); try self.fail(.addDomain) },
                seedDatabase: { fallback in
                    #expect(fallback == "fallback")
                    self.actions.append("seed")
                    try self.fail(.seedDatabase)
                    return "provider"
                }
            ))
            try await coordinator.run { self.events.append($0) }
        }
    }
}
