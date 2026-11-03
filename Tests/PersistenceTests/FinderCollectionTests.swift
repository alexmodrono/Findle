import XCTest
import SQLite3
@testable import FindlePersistence
@testable import SharedDomain

/// Recently Added, Due This Week and Kept Offline: links to items across courses.
final class FinderCollectionTests: XCTestCase {
    private var path: String!
    private var database: Database!
    private let site = "site-1"
    private let synced = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "collections-\(UUID().uuidString).db"
        database = try Database(path: path)
        try database.saveCourses([MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: site),
                                  MoodleCourse(id: 2, shortName: "PHY", fullName: "Physics", siteID: site)])
        try commit(course: 1, arrived: [])
        try commit(course: 2, arrived: [])
    }

    override func tearDownWithError() throws {
        database = nil
        for suffix in ["", "-wal", "-shm", ".initialization-lock"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func item(_ id: String, parent: String?, course: Int, filename: String? = nil, remoteID: Int = 1,
                      directory: Bool = false) -> LocalItem {
        LocalItem(id: id, parentID: parent, siteID: site, courseID: course, remoteID: remoteID, filename: filename ?? id,
                  isDirectory: directory, contentVersion: directory ? nil : "1")
    }

    /// Algebra > Week 1 > Lab.pdf, Algebra > Week 1 > Essay (assignment 77); Physics > Lab.pdf.
    private func commit(course: Int, arrived: [String], at date: Date? = nil) throws {
        let items = course == 1
            ? [item("c1", parent: nil, course: 1, filename: "Algebra", directory: true),
               item("w1", parent: "c1", course: 1, filename: "Week 1", directory: true),
               item("lab-a", parent: "w1", course: 1, filename: "Lab.pdf"),
               item("assign-site-1-1-77", parent: "w1", course: 1, filename: "Essay", remoteID: 77, directory: true)]
            : [item("c2", parent: nil, course: 2, filename: "Physics", directory: true),
               item("lab-p", parent: "c2", course: 2, filename: "Lab.pdf")]
        try database.commitCourseSync(
            items: items, deletingItemIDs: [],
            cursor: SyncCursor(courseID: course, siteID: site, lastSyncDate: date ?? synced, itemCount: items.count),
            outline: CourseOutlineSnapshot(courseID: course, capturedAt: synced, sections: []), arrivedItemIDs: arrived)
    }

    private func entries(_ collection: FinderCollection) throws -> [String: String] {
        let rows = try database.fetchItems(parentID: collection.folderID(siteID: site), siteID: site)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.filename, $0.linkTarget ?? "") })
    }

    func testTheCollectionsSitAtTheRoot() throws {
        let root = try database.fetchItems(parentID: nil, siteID: site).filter(\.isInFinderCollection)
        XCTAssertEqual(Set(root.map(\.filename)), ["Recently Added", "Due This Week", "Kept Offline"])
        XCTAssertTrue(root.allSatisfy(\.isDirectory))
    }

    func testRecentlyAddedLinksToNewItemsUntilTheyAreSeen() throws {
        try commit(course: 1, arrived: ["lab-a"])
        try commit(course: 2, arrived: ["lab-p"])
        XCTAssertEqual(try entries(.recentlyAdded), ["Lab.pdf": "../Algebra/Week 1/Lab.pdf",
                                                     "Lab (PHY).pdf": "../Physics/Lab.pdf"],
                       "Names from different courses don't clash")

        let anchor = try database.currentChangeCounter()
        try database.markItemOpened(id: "w1", at: synced.addingTimeInterval(1))
        XCTAssertEqual(try entries(.recentlyAdded), ["Lab.pdf": "../Physics/Lab.pdf"])
        let gone = try database.fetchPendingDeletionsSince(anchor: anchor, siteID: site, through: try database.currentChangeCounter())
        XCTAssertTrue(gone.contains(FinderCollection.recentlyAdded.entryID(siteID: site, itemID: "lab-a")),
                      "Finder hears that the entry left")
    }

    func testKeptOfflineLinksToWhatTheUserKept() throws {
        try database.pinItemsRecursively(id: "w1", isPinned: true)
        try database.pinItemsRecursively(id: "lab-p", isPinned: true)
        XCTAssertEqual(try entries(.keptOffline), ["Week 1": "../Algebra/Week 1", "Lab.pdf": "../Physics/Lab.pdf"],
                       "A kept folder is one entry, not one per file")
        try database.pinItemsRecursively(id: "w1", isPinned: false)
        XCTAssertEqual(try entries(.keptOffline), ["Lab.pdf": "../Physics/Lab.pdf"])
    }

    func testDueThisWeekLinksToAssignmentsDueInTheNextSevenDays() throws {
        let now = Date()
        try database.saveAssignments([MoodleAssignment(id: 5, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(6 * 86_400),
                                                       moduleID: 77)], siteID: site)
        XCTAssertEqual(try entries(.dueThisWeek), ["Essay": "../Algebra/Week 1/Essay"])
        try database.refreshBadges(siteID: site, now: now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(try entries(.dueThisWeek), [:])
    }

    func testAnUnchangedRefreshWritesNothing() throws {
        try commit(course: 1, arrived: ["lab-a"])
        let anchor = try database.currentChangeCounter()
        XCTAssertFalse(try database.refreshBadges(siteID: site))
        XCTAssertEqual(try database.currentChangeCounter(), anchor)
    }
}

/// Signing out or wiping Findle removes everything kept per site.
final class SiteDataCleanupTests: XCTestCase {
    func testRemovingTheAccountOrEverythingLeavesNoPerSiteRows() throws {
        for wipeAll in [false, true] {
            let path = NSTemporaryDirectory() + "cleanup-\(UUID().uuidString).db"
            defer { for suffix in ["", "-wal", "-shm", ".initialization-lock"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
            let database = try Database(path: path)
            let site = MoodleSite(id: "s", displayName: "Campus", baseURL: URL(string: "https://moodle.example.edu")!)
            try database.saveSite(site)
            try database.saveAccount(Account(id: "acct", siteID: "s", userID: 1, state: .authenticated(userID: 1), createdAt: Date()))
            let items = [LocalItem(id: "c", siteID: "s", courseID: 1, remoteID: 1, filename: "C", isDirectory: true),
                         LocalItem(id: "f", parentID: "c", siteID: "s", courseID: 1, remoteID: 2, filename: "f.pdf", contentVersion: "1")]
            try database.commitCourseSync(items: items, deletingItemIDs: [],
                                          cursor: SyncCursor(courseID: 1, siteID: "s", lastSyncDate: Date(), itemCount: 2),
                                          outline: CourseOutlineSnapshot(courseID: 1, capturedAt: Date(), sections: []),
                                          arrivedItemIDs: ["f"], generatedContents: ["f": Data("x".utf8)])
            try database.saveActivityCompletion([ActivityCompletion(moduleID: 2, courseID: 1, isManual: true, isComplete: true)],
                                                courseID: 1, siteID: "s")
            try database.savePreviousVersion(itemID: "f", siteID: "s", courseID: 1, path: "/tmp/f (previous).pdf", size: 1)
            XCTAssertNotNil(try database.previousVersionPath(itemID: "f"))
            XCTAssertNotNil(try database.fetchGeneratedContent(itemID: "f"))
            XCTAssertEqual(try database.fetchNewItems(courseID: 1, siteID: "s").map(\.id), ["f"])
            XCTAssertEqual(try rows(in: "item_activity", at: path), 1)
            XCTAssertEqual(try rows(in: "activity_completion", at: path), 1)

            if wipeAll { try database.deleteAllData() } else { try database.deleteAccount(id: "acct") }

            XCTAssertNil(try database.previousVersionPath(itemID: "f"), "wipeAll: \(wipeAll)")
            XCTAssertNil(try database.fetchGeneratedContent(itemID: "f"), "wipeAll: \(wipeAll)")
            XCTAssertEqual(try database.previousVersionBytes(courseID: 1, siteID: "s"), 0, "wipeAll: \(wipeAll)")
            XCTAssertEqual(try database.fetchNewItems(courseID: 1, siteID: "s"), [], "wipeAll: \(wipeAll)")
            XCTAssertEqual(try rows(in: "item_activity", at: path), 0, "wipeAll: \(wipeAll)")
            XCTAssertEqual(try rows(in: "activity_completion", at: path), 0, "wipeAll: \(wipeAll)")
        }
    }

    /// Counts a table's rows directly, for tables the database has no reader for.
    private func rows(in table: String, at path: String) throws -> Int64 {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return sqlite3_column_int64(statement, 0)
    }
}
