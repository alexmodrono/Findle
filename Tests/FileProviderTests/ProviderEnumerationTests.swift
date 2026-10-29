import XCTest
import FileProvider
import SQLite3
import Synchronization
import SharedDomain
import FindlePersistence

final class ProviderEnumerationTests: XCTestCase {
    private func fixture() throws -> ProviderFixture {
        let fixture = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }

    func testUnavailableStorageAndKeychainAreTransientButSignOutIsNot() throws {
        let f = try fixture()
        assertProviderError(.serverUnreachable) {
            _ = try ProviderAccess.enumerationDatabase(nil, siteID: "a") { _ in "token" }
        }
        try f.database.setSeedComplete(false)
        assertProviderError(.serverUnreachable) {
            _ = try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in "token" }
        }
        try f.database.setSeedComplete(true)
        assertProviderError(.serverUnreachable) {
            _ = try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in throw CocoaError(.fileReadNoPermission) }
        }
        assertProviderError(.notAuthenticated) {
            _ = try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in nil }
        }
        XCTAssertTrue(try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in "token" } === f.database)
        try f.database.deleteAccount(id: "account-a")
        assertProviderError(.notAuthenticated) {
            _ = try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in "token" }
        }
    }

    func testRootChildAndWorkingSetKeepDomainScopeAndStableParents() throws {
        let f = try fixture()
        let root = EnumerationObserver()
        ItemEnumerator(containerIdentifier: .rootContainer, database: f.database, siteID: "a")
            .enumerateItems(for: root, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        XCTAssertEqual(root.items.map(\.itemIdentifier.rawValue), ["root-a"])
        XCTAssertEqual(root.items.first?.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(root.completions, 1)

        let child = EnumerationObserver()
        ItemEnumerator(containerIdentifier: .init("root-a"), database: f.database, siteID: "a")
            .enumerateItems(for: child, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        XCTAssertEqual(child.items.map(\.itemIdentifier.rawValue), ["file-a"])
        XCTAssertEqual(child.items.first?.parentItemIdentifier.rawValue, "root-a")

        let working = EnumerationObserver()
        WorkingSetEnumerator(database: f.database, siteID: "a").enumerateItems(for: working, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        XCTAssertEqual(Set(working.items.map(\.itemIdentifier.rawValue)), ["root-a", "file-a"])
        XCTAssertEqual(working.completions, 1)
        let unknown = EnumerationObserver()
        WorkingSetEnumerator(database: f.database).enumerateItems(for: unknown, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        XCTAssertTrue(unknown.items.isEmpty)
        XCTAssertEqual((unknown.error as? NSFileProviderError)?.code, .serverUnreachable)
    }

    func testMalformedNegativeOverflowingAndFutureAnchorsExpire() throws {
        let f = try fixture()
        let enumerators: [NSFileProviderEnumerator] = [
            ItemEnumerator(containerIdentifier: .rootContainer, database: f.database, siteID: "a"),
            WorkingSetEnumerator(database: f.database, siteID: "a")
        ]
        for enumerator in enumerators {
            for invalid in ["", "-1", "garbage", "9223372036854775808", String(Int64.max)] {
                let observer = EnumerationObserver()
                enumerator.enumerateChanges?(for: observer, from: .init(Data(invalid.utf8)))
                XCTAssertEqual((observer.error as? NSFileProviderError)?.code, .syncAnchorExpired)
                XCTAssertNil(observer.anchor)
                XCTAssertTrue(observer.items.isEmpty)
                XCTAssertEqual(observer.completions, 1)
            }
        }
    }

    func testChangesHaveStableAnchorsAndScopedTombstonesAfterRestart() throws {
        let f = try fixture()
        let before = try f.database.currentChangeCounter()
        try f.database.updateItemFilename(id: "file-a", filename: "new.pdf")
        try f.database.savePendingDeletions(["gone-a"], siteID: "a")
        try f.database.savePendingDeletions(["gone-b"], siteID: "b")
        let observer = EnumerationObserver()
        WorkingSetEnumerator(database: f.database, siteID: "a").enumerateChanges(for: observer, from: SyncAnchorCoding.encode(before))
        XCTAssertEqual(observer.items.map(\.itemIdentifier.rawValue), ["file-a"])
        XCTAssertEqual(observer.deleted.map(\.rawValue), ["gone-a"])
        let anchor = try XCTUnwrap(observer.anchor)
        XCTAssertEqual(try SyncAnchorCoding.decode(anchor), try f.database.currentChangeCounter())
        let restarted = try Database(path: f.path)
        let again = EnumerationObserver()
        WorkingSetEnumerator(database: restarted, siteID: "a").enumerateChanges(for: again, from: anchor)
        XCTAssertTrue(again.items.isEmpty)
        XCTAssertTrue(again.deleted.isEmpty)
        XCTAssertEqual(again.anchor, anchor)
        XCTAssertEqual(again.completions, 1)
    }

    func testFailedAnchorReadReturnsNilInsteadOfZero() throws {
        let f = try fixture()
        try providerSQL("DELETE FROM system_metadata WHERE key = 'change_counter'", path: f.path)
        XCTAssertThrowsError(try f.database.currentChangeCounter())
        for enumerator in [
            ItemEnumerator(containerIdentifier: .rootContainer, database: f.database, siteID: "a") as NSFileProviderEnumerator,
            WorkingSetEnumerator(database: f.database, siteID: "a")
        ] {
            let calls = Mutex(0)
            enumerator.currentSyncAnchor? { anchor in calls.withLock { $0 += 1 }; XCTAssertNil(anchor) }
            XCTAssertEqual(calls.withLock { $0 }, 1)
        }
    }

    func testTombstoneReadFailureDoesNotPublishPartialChanges() throws {
        let f = try fixture()
        try providerSQL("DROP TABLE pending_deletions", path: f.path)
        let observer = EnumerationObserver()
        WorkingSetEnumerator(database: f.database, siteID: "a").enumerateChanges(for: observer, from: SyncAnchorCoding.encode(0))
        XCTAssertTrue(observer.items.isEmpty)
        XCTAssertNil(observer.anchor)
        XCTAssertEqual((observer.error as? NSFileProviderError)?.code, .serverUnreachable)
        XCTAssertEqual(observer.completions, 1)
    }

    func testSQLiteStepFailuresDoNotBecomeMissingRowsOrSignedOutAccounts() throws {
        let f = try fixture()
        try providerSQL("""
            DROP TABLE accounts;
            CREATE VIEW accounts AS SELECT 'x' AS id, 'a' AS site_id,
              abs(-9223372036854775808) AS user_id, 'authenticated' AS state,
              NULL AS last_sync_date, 0 AS created_at;
            """, path: f.path)
        XCTAssertThrowsError(try f.database.fetchAccounts())
        assertProviderError(.serverUnreachable) {
            _ = try ProviderAccess.enumerationDatabase(f.database, siteID: "a") { _ in "token" }
        }
        try providerSQL("DROP TABLE items; CREATE VIEW items AS SELECT abs(-9223372036854775808) AS id", path: f.path)
        XCTAssertThrowsError(try f.database.fetchItem(id: "missing"))
        try providerSQL("""
            DROP TABLE pending_deletions;
            CREATE VIEW pending_deletions AS SELECT abs(-9223372036854775808) AS item_id,
              'a' AS site_id, 1 AS deleted_at_counter;
            """, path: f.path)
        XCTAssertThrowsError(try f.database.fetchPendingDeletionsSince(anchor: 0, siteID: "a", through: nil))
    }
}

final class EnumerationObserver: NSObject, NSFileProviderEnumerationObserver, NSFileProviderChangeObserver {
    var items: [NSFileProviderItem] = []
    var deleted: [NSFileProviderItemIdentifier] = []
    var anchor: NSFileProviderSyncAnchor?
    var error: Error?
    var completions = 0
    func didEnumerate(_ items: [NSFileProviderItem]) { self.items += items }
    func didUpdate(_ items: [NSFileProviderItem]) { self.items += items }
    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) { deleted += identifiers }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { completions += 1 }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        self.anchor = anchor; completions += 1
    }
    func finishEnumeratingWithError(_ error: Error) { self.error = error; completions += 1 }
}

struct ProviderFixture {
    let directory: URL
    let database: Database
    var path: String { directory.appendingPathComponent("findle.db").path }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try Database(path: directory.appendingPathComponent("findle.db").path)
        for siteID in ["a", "b"] {
            try database.saveSite(MoodleSite(id: siteID, displayName: siteID, baseURL: URL(string: "https://moodle.test")!))
            try database.saveAccount(Account(id: "account-" + siteID, siteID: siteID, userID: 1, state: .authenticated(userID: 1)))
            try database.saveItems([
                LocalItem(id: "root-" + siteID, siteID: siteID, courseID: 1, remoteID: 1, filename: siteID, isDirectory: true),
                LocalItem(id: "file-" + siteID, parentID: "root-" + siteID, siteID: siteID, courseID: 1, remoteID: 2,
                          filename: "file.pdf", contentType: "application/pdf", fileSize: 3, syncState: .downloading,
                          remoteURL: URL(string: "https://moodle.test/file"), contentVersion: "v1")
            ])
        }
        try database.setSeedComplete(true)
    }
}

func providerSQL(_ sql: String, path: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(path, &connection) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}

func assertProviderError(_ expected: NSFileProviderError.Code, operation: () throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) {
    do { try operation(); XCTFail("Expected File Provider error", file: file, line: line) }
    catch { XCTAssertEqual((error as? NSFileProviderError)?.code, expected, file: file, line: line) }
}
