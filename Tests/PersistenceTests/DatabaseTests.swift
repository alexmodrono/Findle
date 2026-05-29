// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import SQLite3
@testable import FoodlePersistence
@testable import SharedDomain

final class DatabaseTests: XCTestCase {
    var database: Database!
    var tempPath: String!

    override func setUp() async throws {
        tempPath = NSTemporaryDirectory() + "foodle_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Site Tests

    func testSaveFetchSite() throws {
        let site = MoodleSite(
            id: "test-site-1",
            displayName: "Test University",
            baseURL: URL(string: "https://moodle.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                moodleVersion: "2023112300",
                moodleRelease: "4.3.2"
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "test-site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.displayName, "Test University")
        XCTAssertEqual(fetched?.baseURL.absoluteString, "https://moodle.test.edu")
        XCTAssertTrue(fetched?.capabilities.supportsWebServices ?? false)
        XCTAssertEqual(fetched?.capabilities.moodleRelease, "4.3.2")
    }

    func testSaveFetchSiteWithLoginCapabilities() throws {
        let site = MoodleSite(
            id: "sso-site-1",
            displayName: "SSO University",
            baseURL: URL(string: "https://sso.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                moodleVersion: "2024042200",
                moodleRelease: "4.4.0",
                loginType: .browser,
                launchURL: "https://sso.test.edu/auth/mobile/launch"
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "sso-site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.capabilities.loginType, .browser)
        XCTAssertEqual(fetched?.capabilities.launchURL, "https://sso.test.edu/auth/mobile/launch")
        XCTAssertTrue(fetched?.capabilities.requiresSSO ?? false)
    }

    func testSaveFetchSiteWithEmbeddedLogin() throws {
        let site = MoodleSite(
            id: "embedded-site-1",
            displayName: "Embedded University",
            baseURL: URL(string: "https://embedded.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                loginType: .embedded,
                launchURL: nil
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "embedded-site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.capabilities.loginType, .embedded)
        XCTAssertNil(fetched?.capabilities.launchURL)
    }

    func testSaveFetchSiteDefaultsToAppLogin() throws {
        let site = MoodleSite(
            id: "app-site-1",
            displayName: "App University",
            baseURL: URL(string: "https://app.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "app-site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.capabilities.loginType, .app)
        XCTAssertNil(fetched?.capabilities.launchURL)
    }

    func testFetchNonexistentSite() throws {
        let result = try database.fetchSite(id: "nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - Schema v3 Fields (wwwroot, httpswwwroot, showLoginForm)

    func testSaveFetchSiteWithDiscoveredRoots() throws {
        let site = MoodleSite(
            id: "v3-site-1",
            displayName: "V3 University",
            baseURL: URL(string: "https://v3.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                loginType: .embedded,
                launchURL: "https://v3.test.edu/admin/tool/mobile/launch.php",
                wwwroot: "https://v3.test.edu",
                httpswwwroot: "https://v3.test.edu",
                showLoginForm: false
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "v3-site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.capabilities.wwwroot, "https://v3.test.edu")
        XCTAssertEqual(fetched?.capabilities.httpswwwroot, "https://v3.test.edu")
        XCTAssertEqual(fetched?.capabilities.showLoginForm, false)
        XCTAssertEqual(fetched?.capabilities.loginType, .embedded)
        XCTAssertEqual(fetched?.capabilities.launchURL, "https://v3.test.edu/admin/tool/mobile/launch.php")
    }

    func testSaveFetchSiteNilDiscoveredRoots() throws {
        let site = MoodleSite(
            id: "v3-nil-site",
            displayName: "Nil Roots",
            baseURL: URL(string: "https://nil.test.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                loginType: .app
            )
        )

        try database.saveSite(site)
        let fetched = try database.fetchSite(id: "v3-nil-site")

        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.capabilities.wwwroot)
        XCTAssertNil(fetched?.capabilities.httpswwwroot)
        XCTAssertEqual(fetched?.capabilities.showLoginForm, true)
    }

    // MARK: - Account Tests

    func testSaveFetchAccount() throws {
        let site = MoodleSite(id: "site-1", displayName: "Test", baseURL: URL(string: "https://test.edu")!)
        try database.saveSite(site)

        let account = Account(
            id: "acct-1",
            siteID: "site-1",
            userID: 42,
            state: .authenticated(userID: 42)
        )
        try database.saveAccount(account)

        let accounts = try database.fetchAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].id, "acct-1")
        XCTAssertEqual(accounts[0].userID, 42)
    }

    // MARK: - Course Tests

    func testSaveFetchCourses() throws {
        let courses = [
            MoodleCourse(id: 101, shortName: "CS101", fullName: "Intro to CS", siteID: "site-1"),
            MoodleCourse(id: 102, shortName: "MATH201", fullName: "Linear Algebra", siteID: "site-1"),
        ]

        try database.saveCourses(courses)
        let fetched = try database.fetchCourses(siteID: "site-1")

        XCTAssertEqual(fetched.count, 2)
        // Sorted by full_name
        XCTAssertEqual(fetched[0].fullName, "Intro to CS")
        XCTAssertEqual(fetched[1].fullName, "Linear Algebra")
    }

    // MARK: - Item Tests

    func testSaveFetchItems() throws {
        let items = [
            LocalItem(
                id: "item-1",
                parentID: nil,
                siteID: "site-1",
                courseID: 101,
                remoteID: 1,
                filename: "Course Folder",
                isDirectory: true,
                syncState: .materialized
            ),
            LocalItem(
                id: "item-2",
                parentID: "item-1",
                siteID: "site-1",
                courseID: 101,
                remoteID: 2,
                filename: "syllabus.pdf",
                isDirectory: false,
                contentType: "application/pdf",
                fileSize: 245760,
                syncState: .placeholder,
                remoteURL: URL(string: "https://test.edu/file.pdf")
            ),
        ]

        try database.saveItems(items)

        // Fetch root items
        let rootItems = try database.fetchItems(parentID: nil)
        XCTAssertEqual(rootItems.count, 1)
        XCTAssertEqual(rootItems[0].filename, "Course Folder")

        // Fetch children
        let children = try database.fetchItems(parentID: "item-1")
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].filename, "syllabus.pdf")
        XCTAssertEqual(children[0].fileSize, 245760)
    }

    func testFetchItemByID() throws {
        let item = LocalItem(
            id: "item-x",
            siteID: "site-1",
            courseID: 101,
            remoteID: 1,
            filename: "test.pdf"
        )
        try database.saveItems([item])

        let fetched = try database.fetchItem(id: "item-x")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.filename, "test.pdf")

        let notFound = try database.fetchItem(id: "nonexistent")
        XCTAssertNil(notFound)
    }

    func testUpdateItemSyncState() throws {
        let item = LocalItem(
            id: "item-state",
            siteID: "site-1",
            courseID: 101,
            remoteID: 1,
            filename: "file.pdf",
            syncState: .placeholder
        )
        try database.saveItems([item])

        try database.updateItemSyncState(id: "item-state", state: .materialized, localPath: "/tmp/file.pdf")

        let fetched = try database.fetchItem(id: "item-state")
        XCTAssertEqual(fetched?.syncState, .materialized)
        XCTAssertEqual(fetched?.localPath, "/tmp/file.pdf")
    }

    // MARK: - Sync Cursor Tests

    func testSaveFetchSyncCursor() throws {
        let cursor = SyncCursor(
            courseID: 101,
            siteID: "site-1",
            lastSyncDate: Date(),
            itemCount: 42
        )

        try database.saveSyncCursor(cursor)
        let fetched = try database.fetchSyncCursor(courseID: 101, siteID: "site-1")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.courseID, 101)
        XCTAssertEqual(fetched?.itemCount, 42)
    }

    // MARK: - Maintenance Tests

    func testRebuildIndex() throws {
        XCTAssertNoThrow(try database.rebuildIndex())
    }

    func testDeleteAllData() throws {
        let courses = [
            MoodleCourse(id: 101, shortName: "CS101", fullName: "Test", siteID: "site-1")
        ]
        try database.saveCourses(courses)

        try database.deleteAllData()
        let fetched = try database.fetchCourses(siteID: "site-1")
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - Change Counter / Sync Anchor

    func testOpeningVersion10DatabaseMigratesChangeCounterColumns() throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        try createVersion10Database(at: tempPath)

        database = try Database(path: tempPath)

        try database.saveItems([makeItem(id: "migrated-item")])
        XCTAssertGreaterThan(try database.currentChangeCounter(), 0)
    }

    private func makeItem(id: String, parentID: String? = nil, courseID: Int = 1) -> LocalItem {
        LocalItem(
            id: id,
            parentID: parentID,
            siteID: "site-1",
            courseID: courseID,
            remoteID: 0,
            filename: id,
            isDirectory: false,
            syncState: .placeholder
        )
    }

    private func createVersion10Database(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        guard let db else {
            throw NSError(
                domain: "DatabaseTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open temporary SQLite database"]
            )
        }
        defer { sqlite3_close(db) }

        try executeRawSQL(db, """
            CREATE TABLE sites (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                base_url TEXT NOT NULL,
                supports_web_services INTEGER NOT NULL DEFAULT 0,
                supports_mobile_api INTEGER NOT NULL DEFAULT 0,
                supports_file_download INTEGER NOT NULL DEFAULT 0,
                moodle_version TEXT,
                moodle_release TEXT,
                site_name TEXT,
                created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
                login_type INTEGER NOT NULL DEFAULT 1,
                launch_url TEXT,
                wwwroot TEXT,
                httpswwwroot TEXT,
                show_login_form INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY,
                site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
                user_id INTEGER,
                username TEXT,
                full_name TEXT,
                state TEXT NOT NULL DEFAULT 'disconnected',
                last_sync_date REAL,
                created_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            CREATE TABLE courses (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                short_name TEXT NOT NULL,
                full_name TEXT NOT NULL,
                summary TEXT,
                category_id INTEGER,
                start_date REAL,
                end_date REAL,
                last_accessed REAL,
                visible INTEGER NOT NULL DEFAULT 1,
                subscription_state TEXT NOT NULL DEFAULT 'discovered',
                custom_folder_name TEXT,
                custom_icon_name TEXT,
                PRIMARY KEY (id, site_id)
            );
            CREATE TABLE items (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                site_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                remote_id INTEGER NOT NULL,
                filename TEXT NOT NULL,
                is_directory INTEGER NOT NULL DEFAULT 0,
                content_type TEXT,
                file_size INTEGER NOT NULL DEFAULT 0,
                creation_date REAL,
                modification_date REAL,
                sync_state TEXT NOT NULL DEFAULT 'placeholder',
                is_pinned INTEGER NOT NULL DEFAULT 0,
                local_path TEXT,
                remote_url TEXT,
                content_version TEXT,
                tag_data BLOB,
                is_local INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE sync_cursors (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                last_sync_date REAL NOT NULL,
                last_modified REAL,
                item_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id)
            );
            CREATE TABLE course_tags (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                tag_name TEXT NOT NULL,
                tag_color INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id, tag_name)
            );
            CREATE TABLE pending_deletions (
                item_id TEXT PRIMARY KEY,
                deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            PRAGMA user_version = 10;
        """)
    }

    private func executeRawSQL(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
            throw NSError(
                domain: "DatabaseTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func testChangeCounterIncrementsOnItemInsert() throws {
        let before = try database.currentChangeCounter()
        try database.saveItems([makeItem(id: "item-1")])
        let after = try database.currentChangeCounter()
        XCTAssertGreaterThan(after, before)
    }

    func testChangeCounterIncrementsOnItemUpdate() throws {
        try database.saveItems([makeItem(id: "item-1")])
        let afterInsert = try database.currentChangeCounter()
        try database.updateItemFilename(id: "item-1", filename: "renamed")
        let afterUpdate = try database.currentChangeCounter()
        XCTAssertGreaterThan(afterUpdate, afterInsert)
    }

    func testFetchItemsChangedSinceFiltersByAnchor() throws {
        try database.saveItems([makeItem(id: "old-1")])
        let anchor = try database.currentChangeCounter()
        try database.saveItems([makeItem(id: "new-1"), makeItem(id: "new-2")])

        // Whole-site lookup should return only the items inserted after the anchor.
        let changed = try database.fetchItemsChangedSince(anchor: anchor, siteID: "site-1")
        let changedIDs = Set(changed.map(\.id))
        XCTAssertEqual(changedIDs, Set(["new-1", "new-2"]))
    }

    func testFetchPendingDeletionsSinceFiltersByAnchor() throws {
        try database.saveItems([
            makeItem(id: "to-keep"),
            makeItem(id: "to-delete-1"),
            makeItem(id: "to-delete-2"),
        ])
        let anchor = try database.currentChangeCounter()

        try database.deleteItemsWithTombstone(ids: ["to-delete-1"])
        try database.deleteItemsWithTombstone(ids: ["to-delete-2"])

        let deletedSince = try database.fetchPendingDeletionsSince(anchor: anchor)
        XCTAssertEqual(Set(deletedSince), Set(["to-delete-1", "to-delete-2"]))

        // An anchor newer than both deletions should return nothing.
        let nowAnchor = try database.currentChangeCounter()
        XCTAssertTrue(try database.fetchPendingDeletionsSince(anchor: nowAnchor).isEmpty)
    }
}
