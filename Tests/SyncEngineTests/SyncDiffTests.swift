import XCTest
@testable import SharedDomain

final class SyncDiffTests: XCTestCase {

    func testItemIdentityStability() {
        let item1 = LocalItem(
            id: "file-site1-101-2001-test.pdf",
            siteID: "site1",
            courseID: 101,
            remoteID: 2001,
            filename: "test.pdf",
            contentVersion: "1000"
        )

        let item2 = LocalItem(
            id: "file-site1-101-2001-test.pdf",
            siteID: "site1",
            courseID: 101,
            remoteID: 2001,
            filename: "test.pdf",
            contentVersion: "1000"
        )

        XCTAssertEqual(item1.id, item2.id)
        XCTAssertEqual(item1.contentVersion, item2.contentVersion)
    }

    func testVersionChangeDetection() {
        let old = LocalItem(
            id: "file-1",
            siteID: "s",
            courseID: 1,
            remoteID: 1,
            filename: "test.pdf",
            contentVersion: "1000"
        )

        let new = LocalItem(
            id: "file-1",
            siteID: "s",
            courseID: 1,
            remoteID: 1,
            filename: "test.pdf",
            contentVersion: "2000"
        )

        XCTAssertNotEqual(old.contentVersion, new.contentVersion)
    }

    func testSizeChangeDetection() {
        let old = LocalItem(
            id: "file-1",
            siteID: "s",
            courseID: 1,
            remoteID: 1,
            filename: "test.pdf",
            fileSize: 1000
        )

        let new = LocalItem(
            id: "file-1",
            siteID: "s",
            courseID: 1,
            remoteID: 1,
            filename: "test.pdf",
            fileSize: 2000
        )

        XCTAssertNotEqual(old.fileSize, new.fileSize)
    }

    func testCourseItemIDFormat() {
        let siteID = "abc123"
        let courseID = 101
        let expectedID = "course-abc123-101"
        let itemID = "course-\(siteID)-\(courseID)"
        XCTAssertEqual(itemID, expectedID)
    }

    func testSectionItemIDFormat() {
        let siteID = "abc123"
        let courseID = 101
        let sectionID = 1001
        let expectedID = "section-abc123-101-1001"
        let itemID = "section-\(siteID)-\(courseID)-\(sectionID)"
        XCTAssertEqual(itemID, expectedID)
    }

    func testFileItemIDFormat() {
        let siteID = "abc123"
        let courseID = 101
        let moduleID = 2001
        let filename = "test.pdf"
        let expectedID = "file-abc123-101-2001-test.pdf"
        let itemID = "file-\(siteID)-\(courseID)-\(moduleID)-\(filename)"
        XCTAssertEqual(itemID, expectedID)
    }

    func testSyncStateTransitions() {
        var item = LocalItem(
            id: "test",
            siteID: "s",
            courseID: 1,
            remoteID: 1,
            filename: "test.pdf",
            syncState: .placeholder
        )

        XCTAssertEqual(item.syncState, .placeholder)

        item.syncState = .downloading
        XCTAssertEqual(item.syncState, .downloading)

        item.syncState = .materialized
        XCTAssertEqual(item.syncState, .materialized)

        item.syncState = .evicting
        XCTAssertEqual(item.syncState, .evicting)

        item.syncState = .placeholder
        XCTAssertEqual(item.syncState, .placeholder)
    }

    func testCourseSubscriptionStateTransitions() {
        var state = CourseSubscriptionState.discovered
        XCTAssertEqual(state, .discovered)

        state = .subscribed
        XCTAssertEqual(state, .subscribed)

        state = .syncing
        XCTAssertEqual(state, .syncing)

        state = .synced
        XCTAssertEqual(state, .synced)

        state = .stale
        XCTAssertEqual(state, .stale)
    }
}
