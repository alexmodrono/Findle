import XCTest
import SQLite3
@testable import FindlePersistence
@testable import SharedDomain

/// The badges Finder shows: new since the last visit, kept downloaded, and due soon.
final class ItemBadgeTests: XCTestCase {
    private var path: String!
    private var database: Database!
    private let site = "site-1"
    private let synced = Date(timeIntervalSince1970: 1_000)
    private let assignmentFolder = "assign-site-1-1-77"

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "item-badges-\(UUID().uuidString).db"
        database = try Database(path: path)
        try commit(arrived: [])
    }

    override func tearDownWithError() throws {
        database = nil
        for suffix in ["", "-wal", "-shm", ".initialization-lock"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func item(_ id: String, parent: String?, remoteID: Int = 1, directory: Bool = false) -> LocalItem {
        LocalItem(id: id, parentID: parent, siteID: site, courseID: 1, remoteID: remoteID, filename: id,
                  isDirectory: directory, contentVersion: directory ? nil : "1")
    }

    /// course-1 > week-1 > slides, course-1 > assignment (module 77) > brief.
    private func commit(arrived: [String], at date: Date? = nil) throws {
        let items = [
            item("course-1", parent: nil, directory: true), item("week-1", parent: "course-1", directory: true),
            item("slides", parent: "week-1"),
            item(assignmentFolder, parent: "course-1", remoteID: 77, directory: true),
            item("brief", parent: assignmentFolder, remoteID: 77),
        ]
        try database.commitCourseSync(
            items: items, deletingItemIDs: [],
            cursor: SyncCursor(courseID: 1, siteID: site, lastSyncDate: date ?? synced, itemCount: items.count),
            outline: CourseOutlineSnapshot(courseID: 1, capturedAt: synced, sections: []), arrivedItemIDs: arrived)
    }

    private func badges(_ id: String) throws -> ItemBadges {
        try XCTUnwrap(database.fetchItem(id: id)).badges
    }

    private func newBadges() throws -> Set<String> {
        Set(try database.fetchAllItems(siteID: site).filter { $0.badges.contains(.new) }.map(\.id))
    }

    func testANewFileBadgesItAndEveryFolderAboveIt() throws {
        try commit(arrived: ["slides"])
        XCTAssertEqual(try newBadges(), ["slides", "week-1", "course-1"])
    }

    func testOpeningClearsTheBadgesOfWhatTheUserHasSeen() throws {
        try commit(arrived: ["slides", "brief"])
        XCTAssertEqual(try newBadges(), ["slides", "week-1", "brief", assignmentFolder, "course-1"])

        XCTAssertTrue(try database.markItemOpened(id: "week-1", at: synced.addingTimeInterval(1)))
        XCTAssertEqual(try newBadges(), ["brief", assignmentFolder, "course-1"],
                       "Opening a folder shows its files; the course still holds something unseen")

        XCTAssertTrue(try database.markItemOpened(id: "brief", at: synced.addingTimeInterval(2)))
        XCTAssertEqual(try newBadges(), [])

        XCTAssertFalse(try database.markItemOpened(id: "brief", at: synced.addingTimeInterval(3)),
                       "Opening something already seen changes no badge, so Finder isn't asked to look")
    }

    func testABadgeChangeIsReportedToFinder() throws {
        let before = try database.currentChangeCounter()
        try commit(arrived: ["slides"])
        let afterSync = try database.currentChangeCounter()
        XCTAssertTrue(Set(try database.fetchItemsChangedSince(anchor: before, siteID: site).map(\.id))
            .contains("course-1"), "A folder that gained a new badge is a change, though its row wasn't rewritten")

        try database.markItemOpened(id: "slides", at: synced.addingTimeInterval(1))
        let changed = Set(try database.fetchItemsChangedSince(anchor: afterSync, siteID: site).map(\.id))
        XCTAssertEqual(changed, ["slides", "week-1", "course-1"])
    }

    func testKeptItemsAreBadgedUntilTheDownloadIsRemoved() throws {
        try database.pinItemsRecursively(id: "week-1", isPinned: true)
        XCTAssertEqual(try badges("week-1"), .kept)
        XCTAssertEqual(try badges("slides"), .kept)
        XCTAssertEqual(try badges("course-1"), [])

        try database.pinItemsRecursively(id: "week-1", isPinned: false)
        XCTAssertEqual(try badges("slides"), [])
    }

    func testALaterSyncKeepsWhatIsStillNew() throws {
        try commit(arrived: ["slides"])
        try commit(arrived: [], at: synced.addingTimeInterval(60))
        XCTAssertEqual(try newBadges(), ["slides", "week-1", "course-1"])
    }

    func testAnUnsubmittedAssignmentIsDueSoonForThreeDaysBeforeItsDeadline() throws {
        let now = Date()
        func save(dueIn interval: TimeInterval, submitted: Bool = false, moduleID: Int? = 77) throws {
            try database.saveAssignments([MoodleAssignment(
                id: 5, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(interval),
                moduleID: moduleID, submitted: submitted)], siteID: site)
        }

        try save(dueIn: 4 * 86_400)
        XCTAssertEqual(try badges(assignmentFolder), [])

        try save(dueIn: 2 * 86_400)
        XCTAssertEqual(try badges(assignmentFolder), .dueSoon)
        XCTAssertEqual(try badges("brief"), [], "Only the assignment's folder is due")
        XCTAssertEqual(try database.fetchAssignments(siteID: site).first?.moduleID, 77)

        XCTAssertTrue(try database.refreshBadges(siteID: site, now: now.addingTimeInterval(3 * 86_400)))
        XCTAssertEqual(try badges(assignmentFolder), [], "Once the deadline passes it is no longer due soon")

        try save(dueIn: 2 * 86_400, submitted: true)
        XCTAssertEqual(try badges(assignmentFolder), [])

        try save(dueIn: 2 * 86_400, moduleID: nil)
        XCTAssertEqual(try badges(assignmentFolder), [], "An assignment Findle can't place has no folder to badge")
    }

    func testDueSoonComesFirstBecauseFinderShowsOneBadge() {
        XCTAssertEqual(ItemBadges([.kept, .new, .dueSoon]).ordered, [.dueSoon, .new, .kept])
    }

    func testPersonalFilesNeverGetBadges() throws {
        try database.saveItems([LocalItem(id: "local-notes", parentID: "week-1", siteID: site, courseID: 1, remoteID: 0,
                                          filename: "notes.txt", isPinned: true, isLocal: true)])
        try database.refreshBadges(siteID: site)
        XCTAssertEqual(try badges("local-notes"), [])
    }

    func testUpgradingFromVersion18AddsBadgesAndReportsTheirChanges() throws {
        database = nil
        try raw("""
            ALTER TABLE items DROP COLUMN badges; ALTER TABLE assignments DROP COLUMN module_id;
            DROP TRIGGER items_bump_after_update;
            CREATE TRIGGER items_bump_after_update AFTER UPDATE OF parent_id, filename ON items
            BEGIN
                UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                UPDATE items SET updated_at = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE id = NEW.id;
            END;
            PRAGMA user_version = 18;
            """)
        database = try Database(path: path)
        XCTAssertEqual(try scalar("PRAGMA user_version"), Int64(Database.schemaVersion))

        let before = try database.currentChangeCounter()
        try database.pinItemsRecursively(id: "slides", isPinned: true)
        XCTAssertEqual(try badges("slides"), .kept)
        XCTAssertGreaterThan(try database.currentChangeCounter(), before)
    }

    private func raw(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
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
