import XCTest
import SharedDomain
@testable import FindlePersistence
import SQLite3

final class DatabaseDiagnosticsTests: XCTestCase {
    func testDiagnosticsCanReadImmediatelyAfterWriterEnablesWAL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for migrating in [false, true] {
            let path = root.appendingPathComponent(migrating ? "migration.db" : "new.db").path
            if migrating {
                let initial = try Database(path: path)
                try initial.setSeedComplete(true)
                try initial.execute("PRAGMA journal_mode = DELETE")
                try initial.execute("PRAGMA user_version = 10")
            }

            let writer = try Database(path: path)
            // No application query may prime WAL for us. A newly returned
            // writer must already support an independent true read-only probe.
            let snapshot = withExtendedLifetime(writer) {
                DatabaseDiagnostics.capture(path: path, siteID: nil)
            }
            XCTAssertNil(snapshot.failure, "Immediate diagnostic failed; migrating: \(migrating)")
            XCTAssertEqual(snapshot.schemaVersion, Database.schemaVersion)
            XCTAssertEqual(snapshot.seedComplete, migrating)
            XCTAssertEqual(snapshot.changeCounter, 0)
        }
    }

    func testConcurrentDiagnosticsAndSchemaOpenersPreserveCommittedHealth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1000)

        // Each round starts a distinct cold migration. A failure is never
        // retried; all readers and writers are released from the same barrier.
        for round in 0..<6 {
            let path = root.appendingPathComponent("migration-\(round).db").path
            do {
                let initial = try Database(path: path)
                try initial.setSeedComplete(true)
                try initial.saveSyncCursor(SyncCursor(courseID: 1, siteID: "one", lastSyncDate: date, itemCount: 2))
                // Keep the existing layout readable by diagnostics while
                // requiring the next writer to enter the migration transaction.
                try initial.execute("PRAGMA journal_mode = DELETE")
                try initial.execute("PRAGMA user_version = 10")
            }
            let start = DiagnosticDatabaseStartBarrier(participants: 12)
            var snapshots: [DiagnosticDatabaseSnapshot] = []
            var openedDatabases: [Database] = []
            try await withThrowingTaskGroup(of: DiagnosticDatabaseOpenResult.self) { group in
                for worker in 0..<12 {
                    group.addTask {
                        await start.arrive()
                        if worker.isMultiple(of: 3) {
                            let opened = try Database(path: path)
                            guard try opened.isSeedComplete(),
                                  try opened.fetchSyncCursor(courseID: 1, siteID: "one")?.lastSyncDate == date else {
                                throw NSError(domain: "DatabaseDiagnosticsTests", code: 1)
                            }
                            return .database(opened)
                        }
                        return .snapshot(DatabaseDiagnostics.capture(path: path, siteID: "one"))
                    }
                }
                for try await result in group {
                    switch result {
                    case .database(let database): openedDatabases.append(database)
                    case .snapshot(let snapshot): snapshots.append(snapshot)
                    }
                }
            }
            XCTAssertEqual(openedDatabases.count, 4)
            XCTAssertEqual(snapshots.count, 8)
            for snapshot in snapshots {
                XCTAssertNil(snapshot.failure, "Diagnostic failed in migration round \(round)")
                XCTAssertTrue([10, Database.schemaVersion].contains(snapshot.schemaVersion ?? -1))
                XCTAssertEqual(snapshot.seedComplete, true)
                XCTAssertEqual(snapshot.changeCounter, 0)
                XCTAssertEqual(snapshot.cursors.map(\.courseID), [1])
                XCTAssertEqual(snapshot.cursors.first?.lastSuccess, date)
            }
            // Keep the application connections alive during diagnostics. A true
            // read-only probe intentionally cannot recreate missing WAL sidecars
            // after every writer has closed.
            let final = withExtendedLifetime(openedDatabases) {
                DatabaseDiagnostics.capture(path: path, siteID: "one")
            }
            XCTAssertNil(final.failure)
            XCTAssertEqual(final.schemaVersion, Database.schemaVersion)
            XCTAssertEqual(final.seedComplete, true)
            XCTAssertEqual(final.cursors.first?.lastSuccess, date)
        }
    }

    func testFutureSchemaCommittedOnlyInWALIsReadWithoutChangingDatabaseOrWAL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("future.db")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let connection = try XCTUnwrap(pointer)
        defer { sqlite3_close(connection) }
        func execute(_ sql: String) throws {
            let status = sqlite3_exec(connection, sql, nil, nil, nil)
            guard status == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(status)) }
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE system_metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT INTO system_metadata VALUES ('seed_complete', 1), ('change_counter', 40);
            CREATE TABLE future_only (value TEXT);
            PRAGMA user_version = \(Database.schemaVersion);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        let checkpointedMain = try Data(contentsOf: url)
        try execute("BEGIN IMMEDIATE; PRAGMA user_version = 999; INSERT INTO future_only VALUES ('committed-in-wal'); COMMIT;")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let committedWAL = try Data(contentsOf: walURL)
        XCTAssertGreaterThan(committedWAL.count, 32)
        XCTAssertEqual(try Data(contentsOf: url), checkpointedMain)

        for readOnly in [false, true] {
            XCTAssertThrowsError(try Database(path: url.path, readOnly: readOnly)) {
                XCTAssertEqual(($0 as? UnsupportedDatabaseSchemaError)?.version, 999)
            }
        }
        let snapshot = DatabaseDiagnostics.capture(path: url.path, siteID: nil)
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.schemaVersion, 999)
        XCTAssertEqual(snapshot.seedComplete, true)
        XCTAssertEqual(snapshot.changeCounter, 40)
        XCTAssertEqual(try Data(contentsOf: url), checkpointedMain)
        XCTAssertEqual(try Data(contentsOf: walURL), committedWAL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".initialization-lock"))
    }

    func testUnsupportedLayoutStillReportsVersionWithoutAttemptingMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(pointer)
        let before = try Data(contentsOf: url)
        let snapshot = DatabaseDiagnostics.capture(path: url.path, siteID: nil)
        XCTAssertEqual(snapshot.schemaVersion, 999)
        XCTAssertNil(snapshot.seedComplete)
        XCTAssertNotNil(snapshot.failure)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testProbeReadsCommittedHealthAndSiteScopedCursorsWithoutChangingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.db").path
        let db = try Database(path: path)
        try db.setSeedComplete(true)
        let date = Date(timeIntervalSince1970: 1000)
        try db.saveSyncCursor(SyncCursor(courseID: 1, siteID: "one", lastSyncDate: date, itemCount: 2))
        try db.saveSyncCursor(SyncCursor(courseID: 2, siteID: "two", lastSyncDate: date, itemCount: 3))
        let counter = try db.currentChangeCounter()
        let snapshot = DatabaseDiagnostics.capture(path: path, siteID: "one")
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.schemaVersion, Int(Database.schemaVersion))
        XCTAssertEqual(snapshot.seedComplete, true)
        XCTAssertEqual(snapshot.changeCounter, counter)
        XCTAssertEqual(snapshot.cursors.map(\.courseID), [1])
        XCTAssertEqual(snapshot.cursors.first?.lastSuccess, date)
        XCTAssertEqual(try db.currentChangeCounter(), counter)
    }

    func testMissingAndCorruptDatabaseRemainUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing.db")
        XCTAssertNotNil(DatabaseDiagnostics.capture(path: url.path, siteID: nil).failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let original = Data("broken database token=SECRET".utf8)
        try original.write(to: url)
        let snapshot = DatabaseDiagnostics.capture(path: url.path, siteID: nil)
        XCTAssertEqual(snapshot.failure?.domain, "SQLite")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("SECRET"))
    }
}

private enum DiagnosticDatabaseOpenResult: Sendable {
    case database(Database)
    case snapshot(DiagnosticDatabaseSnapshot)
}

private actor DiagnosticDatabaseStartBarrier {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) { self.participants = participants }

    func arrive() async {
        arrivals += 1
        if arrivals == participants {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
