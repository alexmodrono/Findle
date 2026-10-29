import XCTest
import SharedDomain
import FindlePersistence
import SQLite3

final class DatabaseDiagnosticsTests: XCTestCase {
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
