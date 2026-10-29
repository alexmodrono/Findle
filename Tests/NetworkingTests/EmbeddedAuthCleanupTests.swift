import XCTest
import AppKit
import WebKit
import Security
@testable import FindleNetworking
import SharedDomain

@MainActor
final class EmbeddedAuthCleanupTests: XCTestCase {
    private static let site = MoodleSite(displayName: "Test", baseURL: URL(string: "https://example.edu")!,
                                        capabilities: SiteCapabilities(loginType: .embedded))

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRemovalWaitsForActualWebViewReleaseAfterTerminalTeardown() async throws {
        _ = NSApplication.shared
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = expectation(description: "released web view's store removed")
        weak var observed: WKWebView?
        var removals = 0
        let cleanup = EmbeddedWebDataStoreCleanup(storageURL: root.appendingPathComponent("queue.json")) { _ in
            XCTAssertNil(observed, "Removal must follow real WKWebView deallocation")
            removals += 1
            removed.fulfill()
        }
        let coordinator = EmbeddedAuthCoordinator(cleanup: cleanup, storeFactory: { _ in .nonPersistent() })
        var retained: WKWebView?
        try autoreleasepool {
            try coordinator.configure(site: Self.site)
            retained = coordinator.webView
            observed = retained
        }
        let identifier = try XCTUnwrap(cleanup.pendingIdentifiers.first)
        coordinator.cancel()
        XCTAssertNil(coordinator.webView)
        XCTAssertNil(retained?.navigationDelegate)
        XCTAssertNil(retained?.uiDelegate)
        XCTAssertNil(retained?.superview)
        XCTAssertNotNil(observed, "The embedding caller still owns the view")
        cleanup.retryPending()
        await cleanup.waitForScheduledRemovals()
        XCTAssertEqual(removals, 0)
        XCTAssertTrue(cleanup.liveIdentifiers.contains(identifier))
        retained = nil
        await fulfillment(of: [removed], timeout: 5)
        await cleanup.waitForScheduledRemovals()
        XCTAssertNil(observed)
        XCTAssertTrue(cleanup.pendingIdentifiers.isEmpty)
    }

    func testAbandonedCoordinatorReleasesItsViewAndRetiresStore() async throws {
        _ = NSApplication.shared
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = expectation(description: "abandoned attempt removed")
        weak var observed: WKWebView?
        let cleanup = EmbeddedWebDataStoreCleanup(storageURL: root.appendingPathComponent("queue.json")) { _ in
            XCTAssertNil(observed)
            removed.fulfill()
        }
        try autoreleasepool {
            let coordinator = EmbeddedAuthCoordinator(cleanup: cleanup, storeFactory: { _ in .nonPersistent() })
            try coordinator.configure(site: Self.site)
            observed = coordinator.webView
        }
        await fulfillment(of: [removed], timeout: 5)
        await cleanup.waitForScheduledRemovals()
        XCTAssertTrue(cleanup.pendingIdentifiers.isEmpty)
    }

    func testFailedRemovalStaysPersistedAndRetriesAfterRestart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let first = EmbeddedWebDataStoreCleanup(storageURL: file) { _ in
            throw NSError(domain: "WKErrorDomain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "token=private-callback-content"])
        }
        let identifier = try first.registerAttempt()
        first.viewWasReleased(identifier: identifier)
        await first.waitForScheduledRemovals()
        XCTAssertEqual(first.pendingIdentifiers, [identifier])
        var retried: [UUID] = []
        let restarted = EmbeddedWebDataStoreCleanup(storageURL: file) { retried.append($0) }
        XCTAssertEqual(restarted.pendingIdentifiers, [identifier])
        restarted.retryPending()
        await restarted.waitForScheduledRemovals()
        XCTAssertEqual(retried, [identifier])
        XCTAssertTrue(restarted.pendingIdentifiers.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("token"))
    }

    func testRetriesAreBoundedAndProtectLiveAndInFlightAttempts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        try autoreleasepool {
            let abandoned = EmbeddedWebDataStoreCleanup(storageURL: file) { _ in }
            for _ in 0..<6 { _ = try abandoned.registerAttempt() }
        }
        var calls: [UUID] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "removal started")
        let cleanup = EmbeddedWebDataStoreCleanup(storageURL: file) { identifier in
            calls.append(identifier)
            if calls.count == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        let live = try cleanup.registerAttempt()
        cleanup.retryPending(maximum: 2)
        await fulfillment(of: [started], timeout: 2)
        let inFlight = try XCTUnwrap(calls.first)
        XCTAssertThrowsError(try cleanup.registerAttempt(identifier: inFlight))
        XCTAssertFalse(calls.contains(live))
        release?.resume()
        await cleanup.waitForScheduledRemovals()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(cleanup.pendingIdentifiers.count, 5)
        cleanup.retryPending(maximum: 10)
        await cleanup.waitForScheduledRemovals()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(Set(calls).count, 6)
        XCTAssertEqual(cleanup.pendingIdentifiers, [live])
        cleanup.viewWasReleased(identifier: live)
        await cleanup.waitForScheduledRemovals()
    }

    func testFullUnwritableAndCorruptQueuesDoNotAdmitAnUntrackedStore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let full = EmbeddedWebDataStoreCleanup(storageURL: file, maximumEntries: 2) { _ in }
        _ = try full.registerAttempt()
        _ = try full.registerAttempt()
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try full.registerAttempt())
        XCTAssertEqual(try Data(contentsOf: file), before)

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let unwritable = EmbeddedWebDataStoreCleanup(storageURL: blocked.appendingPathComponent("queue.json")) { _ in }
        XCTAssertThrowsError(try unwritable.registerAttempt())
        XCTAssertTrue(unwritable.pendingIdentifiers.isEmpty)
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "keep")

        let corruptFile = root.appendingPathComponent("corrupt.json")
        let corruptData = Data("incomplete queue".utf8)
        try corruptData.write(to: corruptFile)
        let corrupt = EmbeddedWebDataStoreCleanup(storageURL: corruptFile) { _ in }
        XCTAssertThrowsError(try corrupt.registerAttempt())
        XCTAssertEqual(try Data(contentsOf: corruptFile), corruptData)
    }

    func testProcessTerminationAndWindowCloseFinishWaiterAndDetachView() async throws {
        _ = NSApplication.shared
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for processTerminated in [true, false] {
            let released = expectation(description: "terminal view released")
            let cleanup = EmbeddedWebDataStoreCleanup(storageURL: root.appendingPathComponent("\(processTerminated).json")) { _ in
                released.fulfill()
            }
            let coordinator = EmbeddedAuthCoordinator(cleanup: cleanup, storeFactory: { _ in .nonPersistent() })
            try coordinator.configure(site: Self.site)
            var view = coordinator.webView
            let completed = expectation(description: "waiter completed")
            let waiter = Task {
                defer { completed.fulfill() }
                do { _ = try await coordinator.waitForResult(); XCTFail("Terminal event succeeded") }
                catch {
                    if processTerminated {
                        guard case .ssoCallbackInvalid = error as? FindleError else { return XCTFail("Wrong termination failure") }
                    } else {
                        guard case .cancelled = error as? FindleError else { return XCTFail("Wrong closure failure") }
                    }
                }
            }
            if processTerminated { coordinator.webViewWebContentProcessDidTerminate(view!) }
            else { coordinator.webViewDidClose(view!) }
            XCTAssertNil(coordinator.webView)
            XCTAssertNil(view?.navigationDelegate)
            XCTAssertNil(view?.uiDelegate)
            view = nil
            await fulfillment(of: [completed, released], timeout: 5)
            coordinator.cancel()
            await waiter.value
            await cleanup.waitForScheduledRemovals()
        }
    }

    func testPlatformRemovalIsIdempotentForAbsentStoreIdentifier() async throws {
        _ = NSApplication.shared
        let existing = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        var identifier = UUID()
        while existing.contains(identifier) { identifier = UUID() }
        // This never creates a persistent store and cannot select an existing
        // identifier. Exercise the real WebKit API, not the injected remover.
        try await EmbeddedWebDataStoreCleanup.removePersistentStore(identifier)
        try await EmbeddedWebDataStoreCleanup.removePersistentStore(identifier)
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(remaining.contains(identifier))
    }

    func testRandomFailureCreatesNeitherStoreNorPendingIdentifier() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup = EmbeddedWebDataStoreCleanup(storageURL: root.appendingPathComponent("queue.json")) { _ in }
        var storesCreated = 0
        let coordinator = EmbeddedAuthCoordinator(cleanup: cleanup, storeFactory: { _ in
            storesCreated += 1
            return .nonPersistent()
        }, passportGenerator: { try SSONonce.generate(fill: { _ in errSecNotAvailable }) })
        XCTAssertThrowsError(try coordinator.configure(site: Self.site))
        XCTAssertEqual(storesCreated, 0)
        XCTAssertTrue(cleanup.pendingIdentifiers.isEmpty)
        XCTAssertNil(coordinator.webView)
    }
}
