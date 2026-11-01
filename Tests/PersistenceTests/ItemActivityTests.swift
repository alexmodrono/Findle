import XCTest
import SQLite3
@testable import FindlePersistence
@testable import SharedDomain

/// What is new in a course: items a sync brought in that the user hasn't
/// opened, directly or through the folder that holds them.
final class ItemActivityTests: XCTestCase {
    private var path: String!
    private var database: Database!
    private let site = "site-1"
    private let synced = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "item-activity-\(UUID().uuidString).db"
        database = try Database(path: path)
        try commit(courseID: 1, arrived: [])
    }

    override func tearDownWithError() throws {
        database = nil
        for suffix in ["", "-wal", "-shm", ".initialization-lock"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func item(_ id: String, parent: String?, course: Int = 1, directory: Bool = false,
                      personal: Bool = false) -> LocalItem {
        LocalItem(id: id, parentID: parent, siteID: site, courseID: course, remoteID: 1, filename: id,
                  isDirectory: directory, contentVersion: directory ? nil : "1", isLocal: personal)
    }

    /// Course 1: course-1 > week-1 > slides, course-1 > week-2 > lab; course 2: course-2 > reading.
    private func commit(courseID: Int, arrived: [String], at date: Date? = nil, deleting: [String] = []) throws {
        let items: [LocalItem] = courseID == 1
            ? [item("course-1", parent: nil, directory: true), item("week-1", parent: "course-1", directory: true),
               item("slides", parent: "week-1"), item("week-2", parent: "course-1", directory: true),
               item("lab", parent: "week-2")].filter { !deleting.contains($0.id) }
            : [item("course-2", parent: nil, course: 2, directory: true), item("reading", parent: "course-2", course: 2)]
        try database.commitCourseSync(
            items: items, deletingItemIDs: deleting,
            cursor: SyncCursor(courseID: courseID, siteID: site, lastSyncDate: date ?? synced, itemCount: items.count),
            outline: CourseOutlineSnapshot(courseID: courseID, capturedAt: synced, sections: []), arrivedItemIDs: arrived)
    }

    private func newIDs(course: Int = 1) throws -> Set<String> {
        Set(try database.fetchNewItems(courseID: course, siteID: site).map(\.id))
    }

    func testArrivalsAreNewUntilOpenedOrTheirFolderIsOpened() throws {
        try commit(courseID: 1, arrived: ["slides", "lab", "week-2"])
        XCTAssertEqual(try newIDs(), ["slides", "lab", "week-2"])

        try database.markItemOpened(id: "slides", at: synced.addingTimeInterval(1))
        XCTAssertEqual(try newIDs(), ["lab", "week-2"], "Opening a file ends it being new")

        try database.markItemOpened(id: "course-1", at: synced.addingTimeInterval(2))
        XCTAssertEqual(try newIDs(), ["lab"], "Opening the course shows its folders, not what is inside them")

        try database.markItemOpened(id: "week-2", at: synced.addingTimeInterval(3))
        XCTAssertEqual(try newIDs(), [])
    }

    func testChangedContentIsNewAgainAfterBeingSeen() throws {
        try commit(courseID: 1, arrived: ["slides"])
        try database.markItemOpened(id: "week-1", at: synced.addingTimeInterval(1))
        XCTAssertEqual(try newIDs(), [])
        try commit(courseID: 1, arrived: ["slides"], at: synced.addingTimeInterval(10))
        XCTAssertEqual(try newIDs(), ["slides"])
    }

    func testAnEarlierOpenDateNeverReplacesALaterOne() throws {
        try commit(courseID: 1, arrived: ["slides"])
        try database.markItemOpened(id: "slides", at: synced.addingTimeInterval(5))
        try database.markItemOpened(id: "slides", at: synced.addingTimeInterval(-100))
        XCTAssertEqual(try newIDs(), [])
    }

    func testOpeningBeforeTheArrivalDoesNotHideIt() throws {
        try database.markItemOpened(id: "week-1", at: synced.addingTimeInterval(-1))
        try commit(courseID: 1, arrived: ["slides"])
        XCTAssertEqual(try newIDs(), ["slides"])
    }

    func testPersonalFilesAreNeverNew() throws {
        try database.saveItems([item("local-notes", parent: "week-1", personal: true)])
        try commit(courseID: 1, arrived: ["local-notes", "slides"])
        XCTAssertEqual(try newIDs(), ["slides"])
    }

    func testCountsPerCourse() throws {
        try commit(courseID: 2, arrived: [])
        try commit(courseID: 1, arrived: ["slides", "lab"])
        try commit(courseID: 2, arrived: ["reading"])
        XCTAssertEqual(try database.newItemCounts(siteID: site), [1: 2, 2: 1])
        try database.markItemOpened(id: "course-2", at: synced.addingTimeInterval(1))
        XCTAssertEqual(try database.newItemCounts(siteID: site), [1: 2])
        XCTAssertEqual(try database.newItemCounts(siteID: "other-site"), [:])
    }

    func testRemovedItemsForgetTheirActivityAndArriveAgainWhenRestored() throws {
        try commit(courseID: 1, arrived: ["lab"])
        try database.markItemOpened(id: "lab", at: synced.addingTimeInterval(1))
        try commit(courseID: 1, arrived: [], at: synced.addingTimeInterval(2), deleting: ["lab"])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM item_activity WHERE item_id = 'lab'"), 0)
        try commit(courseID: 1, arrived: ["lab"], at: synced.addingTimeInterval(3))
        XCTAssertEqual(try newIDs(), ["lab"])
    }

    func testNewItemsSurviveReopeningTheDatabase() throws {
        try commit(courseID: 1, arrived: ["slides", "lab"])
        try database.markItemOpened(id: "slides", at: synced.addingTimeInterval(1))
        database = nil
        database = try Database(path: path)
        XCTAssertEqual(try newIDs(), ["lab"])
    }

    func testOpeningAnUnknownItemRecordsNothing() throws {
        try database.markItemOpened(id: "missing", at: synced)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM item_activity"), 0)
    }

    func testDeletingTheAccountForgetsItsActivity() throws {
        try database.saveSite(MoodleSite(id: site, displayName: "Site", baseURL: URL(string: "https://moodle.test")!))
        try database.saveAccount(Account(id: "account", siteID: site, userID: 1, state: .authenticated(userID: 1)))
        try commit(courseID: 1, arrived: ["slides"])
        try database.deleteAccount(id: "account")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM item_activity"), 0)
    }

    func testUpgradingFromVersion15AddsActivityWithNothingNew() throws {
        database = nil
        try raw("DROP TABLE item_activity; PRAGMA user_version = 15;")
        database = try Database(path: path)
        XCTAssertEqual(try scalar("PRAGMA user_version"), Int64(Database.schemaVersion))
        XCTAssertEqual(try newIDs(), [])
        try commit(courseID: 1, arrived: ["slides"])
        XCTAssertEqual(try newIDs(), ["slides"])
    }

    private func raw(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return sqlite3_column_int64(statement, 0)
    }
}
