// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import Darwin
import SQLite3
@testable import FindlePersistence
@testable import SharedDomain

final class DatabaseTests: XCTestCase {
    var database: Database!
    var tempPath: String!

    override func setUp() async throws {
        tempPath = NSTemporaryDirectory() + "findle_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        for suffix in ["", "-wal", "-shm", ".initialization-lock"] {
            try? FileManager.default.removeItem(atPath: tempPath + suffix)
        }
    }

    // MARK: - Atomic Course Publication

    func testCourseCommitRollsBackEveryStageAndCanReplayAfterReopening() throws {
        var kept = makeItem(id: "kept")
        kept.tagData = Data("personal tags".utf8)
        kept.localPath = "/tmp/kept.pdf"
        kept.syncState = .materialized
        let removed = makeItem(id: "removed")
        let resurrected = makeItem(id: "resurrected")
        try database.saveItems([resurrected])
        try database.deleteItemsWithTombstone(ids: [resurrected.id])
        let oldCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 100), itemCount: 2)
        let oldOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: oldCursor.lastSyncDate, sections: [CourseOutlineSection(id: 10, name: "Before", sectionNumber: 1)])
        try database.commitCourseSync(items: [kept, removed], deletingItemIDs: [], cursor: oldCursor, outline: oldOutline)
        let oldItems = try database.fetchItems(courseID: 1, siteID: "site-1")
        let anchor = try database.currentChangeCounter()

        var changed = kept
        changed.fileSize = 200
        let added = makeItem(id: "added")
        let nextItems = [changed, added, resurrected]
        let nextCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 200), itemCount: 3)
        let nextOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: nextCursor.lastSyncDate, sections: [CourseOutlineSection(id: 20, name: "After", sectionNumber: 1)])

        // Fail successively after item writes, deletion records, and the cursor.
        // A failed resurrection must also restore its previous tombstone.
        for table in ["items", "pending_deletions", "sync_cursors", "course_outlines"] {
            try database.execute("CREATE TRIGGER reject_publication BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
            XCTAssertThrowsError(try database.commitCourseSync(items: nextItems, deletingItemIDs: [removed.id], cursor: nextCursor, outline: nextOutline), table)
            XCTAssertEqual(try database.fetchItems(courseID: 1, siteID: "site-1"), oldItems, table)
            XCTAssertEqual(try database.fetchSyncCursor(courseID: 1, siteID: "site-1"), oldCursor, table)
            XCTAssertEqual(try database.fetchCourseOutline(courseID: 1, siteID: "site-1"), oldOutline, table)
            XCTAssertEqual(try database.fetchPendingDeletions(), [resurrected.id], table)
            XCTAssertEqual(try database.currentChangeCounter(), anchor, table)
            XCTAssertTrue(try database.fetchItemsChangedSince(anchor: anchor, siteID: "site-1").isEmpty, table)
            try database.execute("DROP TRIGGER reject_publication")
        }

        // Reopen as a new app process would, then retry the same accepted revision.
        database = nil
        database = try Database(path: tempPath)
        try database.commitCourseSync(items: nextItems, deletingItemIDs: [removed.id], cursor: nextCursor, outline: nextOutline)
        XCTAssertEqual(Set(try database.fetchItems(courseID: 1, siteID: "site-1").map(\.id)), Set(nextItems.map(\.id)))
        XCTAssertEqual(try database.fetchItem(id: kept.id), changed)
        XCTAssertEqual(try database.fetchPendingDeletions(), [removed.id])
        XCTAssertEqual(try database.fetchSyncCursor(courseID: 1, siteID: "site-1"), nextCursor)
        XCTAssertEqual(try database.fetchCourseOutline(courseID: 1, siteID: "site-1"), nextOutline)
        XCTAssertGreaterThan(try database.currentChangeCounter(), anchor)
        XCTAssertEqual(Set(try database.fetchItemsChangedSince(anchor: anchor, siteID: "site-1").map(\.id)), Set(nextItems.map(\.id)))
    }

    func testKilledSQLiteWriterLeavesOnlyCompleteCourseRevision() throws {
        let kept = makeItem(id: "kept")
        let removed = makeItem(id: "removed")
        let oldCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 100), itemCount: 2)
        let oldOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: oldCursor.lastSyncDate, sections: [CourseOutlineSection]())
        var changed = kept
        changed.fileSize = 200
        let nextCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 200), itemCount: 1)
        let nextOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: nextCursor.lastSyncDate, sections: [CourseOutlineSection]())
        let payload = String(decoding: try JSONEncoder().encode(nextOutline), as: UTF8.self).replacingOccurrences(of: "'", with: "''")

        for commitBeforeTermination in [false, true] {
            try database.commitCourseSync(items: [kept, removed], deletingItemIDs: [], cursor: oldCursor, outline: oldOutline)
            let anchor = try database.currentChangeCounter()
            // The failure-injection test above checks Database's write sequence.
            // A separate SQLite process exercises the WAL crash boundary without
            // terminating the test runner or touching an installed app's database.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", tempPath]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let sql = """
            .bail on
            .timeout 5000
            BEGIN IMMEDIATE;
            UPDATE items SET file_size = 200 WHERE id = 'kept';
            INSERT INTO pending_deletions (item_id, site_id) VALUES ('removed', 'site-1');
            DELETE FROM items WHERE id = 'removed';
            UPDATE sync_cursors SET last_sync_date = 200, item_count = 1 WHERE course_id = 1 AND site_id = 'site-1';
            UPDATE course_outlines SET payload = '\(payload)' WHERE course_id = 1 AND site_id = 'site-1';
            \(commitBeforeTermination ? "COMMIT;" : "")
            .print ready

            """
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            let marker = output.fileHandleForReading.availableData
            XCTAssertEqual(String(decoding: marker, as: UTF8.self), "ready\n")
            XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            try input.fileHandleForWriting.close()
            try output.fileHandleForReading.close()

            database = nil
            database = try Database(path: tempPath)
            XCTAssertEqual(try database.fetchItem(id: kept.id), commitBeforeTermination ? changed : kept)
            XCTAssertEqual(try database.fetchItem(id: removed.id), commitBeforeTermination ? nil : removed)
            XCTAssertEqual(try database.fetchSyncCursor(courseID: 1, siteID: "site-1"), commitBeforeTermination ? nextCursor : oldCursor)
            XCTAssertEqual(try database.fetchCourseOutline(courseID: 1, siteID: "site-1"), commitBeforeTermination ? nextOutline : oldOutline)
            XCTAssertEqual(try database.fetchPendingDeletions(), commitBeforeTermination ? [removed.id] : [])
            if commitBeforeTermination {
                XCTAssertGreaterThan(try database.currentChangeCounter(), anchor)
            } else {
                XCTAssertEqual(try database.currentChangeCounter(), anchor)
                // Replay the interrupted revision through the real publication API.
                try database.commitCourseSync(items: [changed], deletingItemIDs: [removed.id], cursor: nextCursor, outline: nextOutline)
                XCTAssertEqual(try database.fetchItem(id: kept.id), changed)
                XCTAssertNil(try database.fetchItem(id: removed.id))
                XCTAssertEqual(try database.fetchSyncCursor(courseID: 1, siteID: "site-1"), nextCursor)
                XCTAssertEqual(try database.fetchCourseOutline(courseID: 1, siteID: "site-1"), nextOutline)
            }
        }
    }

    func testCourseCommitKeepsExistingReaderSnapshotsUntilTheyAdvance() throws {
        let old = makeItem(id: "before")
        let next = makeItem(id: "after")
        let oldCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 100), itemCount: 1)
        let oldOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: oldCursor.lastSyncDate, sections: [CourseOutlineSection]())
        try database.commitCourseSync(items: [old], deletingItemIDs: [], cursor: oldCursor, outline: oldOutline)
        let anchor = try database.currentChangeCounter()
        // Independent connections model the app, extension, and helper readers.
        let readers = try (0..<3).map { _ in try Database(path: tempPath, readOnly: true) }
        for reader in readers {
            try reader.execute("BEGIN DEFERRED TRANSACTION")
            XCTAssertEqual(try reader.fetchItems(courseID: 1, siteID: "site-1"), [old])
        }
        let nextCursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 200), itemCount: 1)
        let nextOutline = CourseOutlineSnapshot(courseID: 1, capturedAt: nextCursor.lastSyncDate, sections: [CourseOutlineSection]())
        try database.commitCourseSync(items: [next], deletingItemIDs: [old.id], cursor: nextCursor, outline: nextOutline)
        for reader in readers {
            XCTAssertEqual(try reader.fetchItems(courseID: 1, siteID: "site-1"), [old])
            XCTAssertEqual(try reader.fetchSyncCursor(courseID: 1, siteID: "site-1"), oldCursor)
            XCTAssertEqual(try reader.fetchCourseOutline(courseID: 1, siteID: "site-1"), oldOutline)
            XCTAssertTrue(try reader.fetchPendingDeletions().isEmpty)
            XCTAssertEqual(try reader.currentChangeCounter(), anchor)
            try reader.execute("COMMIT")
            XCTAssertEqual(try reader.fetchItems(courseID: 1, siteID: "site-1"), [next])
            XCTAssertEqual(try reader.fetchSyncCursor(courseID: 1, siteID: "site-1"), nextCursor)
            XCTAssertEqual(try reader.fetchCourseOutline(courseID: 1, siteID: "site-1"), nextOutline)
            XCTAssertEqual(try reader.fetchPendingDeletions(), [old.id])
            XCTAssertGreaterThan(try reader.currentChangeCounter(), anchor)
        }
    }

    func testConcurrentCourseReadersSeeCoherentRevisions() async throws {
        let writer = try XCTUnwrap(database)
        let readers = try (0..<3).map { _ in try Database(path: tempPath, readOnly: true) }
        let original = makeItem(id: "revision")
        let cursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: Date(timeIntervalSince1970: 0), itemCount: 1)
        let outline = CourseOutlineSnapshot(courseID: 1, capturedAt: cursor.lastSyncDate, sections: [CourseOutlineSection]())
        try writer.commitCourseSync(items: [original], deletingItemIDs: [], cursor: cursor, outline: outline)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for revision in 1...30 {
                    var item = original
                    item.fileSize = Int64(revision)
                    let date = Date(timeIntervalSince1970: TimeInterval(revision))
                    let cursor = SyncCursor(courseID: 1, siteID: "site-1", lastSyncDate: date, itemCount: 1)
                    let outline = CourseOutlineSnapshot(courseID: 1, capturedAt: date, sections: [CourseOutlineSection]())
                    try writer.commitCourseSync(items: [item], deletingItemIDs: [], cursor: cursor, outline: outline)
                    await Task.yield()
                }
            }
            for reader in readers {
                group.addTask {
                    var priorCounter: Int64 = 0
                    for _ in 0..<60 {
                        try reader.execute("BEGIN DEFERRED TRANSACTION")
                        do {
                            let item = try XCTUnwrap(reader.fetchItem(id: original.id))
                            let cursor = try XCTUnwrap(reader.fetchSyncCursor(courseID: 1, siteID: "site-1"))
                            let outline = try XCTUnwrap(reader.fetchCourseOutline(courseID: 1, siteID: "site-1"))
                            let counter = try reader.currentChangeCounter()
                            XCTAssertEqual(TimeInterval(item.fileSize), cursor.lastSyncDate.timeIntervalSince1970)
                            XCTAssertEqual(cursor.lastSyncDate, outline.capturedAt)
                            XCTAssertGreaterThanOrEqual(counter, priorCounter)
                            priorCounter = counter
                            try reader.execute("COMMIT")
                        } catch {
                            try? reader.execute("ROLLBACK")
                            throw error
                        }
                        await Task.yield()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try writer.fetchItem(id: original.id)?.fileSize, 30)
    }

    // MARK: - Site Tests

    func testRefreshingSiteKeepsExistingAccountAndCourses() throws {
        let site = MoodleSite(id: "reconnect-site", displayName: "Before", baseURL: URL(string: "https://example.edu")!)
        let account = Account(id: "existing-account", siteID: site.id, userID: 42, state: .authenticated(userID: 42),
                              lastSyncDate: Date(timeIntervalSince1970: 200), createdAt: Date(timeIntervalSince1970: 100))
        let course = MoodleCourse(id: 101, shortName: "CS101", fullName: "Course", siteID: site.id)
        try database.saveSite(site)
        try database.saveAccount(account)
        try database.saveCourses([course])
        let before = try database.fetchCourses(siteID: site.id)
        let updated = MoodleSite(id: site.id, displayName: "After", baseURL: site.baseURL,
                                 capabilities: SiteCapabilities(loginType: .embedded))
        try database.saveSite(updated)
        // Assert before saving the account again: REPLACE used to cascade-delete it.
        XCTAssertEqual(try database.fetchAccounts(), [account])
        XCTAssertEqual(try database.fetchCourses(siteID: site.id), before)
        XCTAssertEqual(try database.fetchSite(id: site.id)?.displayName, "After")
        XCTAssertEqual(try database.fetchSite(id: site.id)?.capabilities.loginType, .embedded)
    }

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

    func testSaveFetchCourseOutline() throws {
        let outline = CourseOutlineSnapshot(
            courseID: 101,
            sections: [
                CourseOutlineSection(
                    id: 4,
                    name: "Week 1",
                    summary: "Introduction",
                    sectionNumber: 1,
                    modules: [CourseOutlineModule(id: 8, name: "Reading", type: "resource")]
                )
            ]
        )

        try database.saveCourseOutline(outline, siteID: "site-1")

        let fetched = try database.fetchCourseOutline(courseID: 101, siteID: "site-1")
        XCTAssertEqual(fetched, outline)
        XCTAssertEqual(try database.fetchCourseOutlines(siteID: "site-1").count, 1)
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

    func testFetchItemPreservesLocalFlagOnCurrentSchema() throws {
        let item = LocalItem(
            id: "local-flag",
            siteID: "site-1",
            courseID: 101,
            remoteID: 0,
            filename: "workspace",
            isDirectory: true,
            isLocal: true
        )
        try database.saveItems([item])

        XCTAssertTrue(try database.fetchItem(id: item.id)?.isLocal == true)
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

    func testSeedCompletionIsExplicitAndResetByDeleteAllData() throws {
        XCTAssertFalse(try database.isSeedComplete())
        try database.setSeedComplete(true)
        XCTAssertTrue(try database.isSeedComplete())

        try database.deleteAllData()

        XCTAssertFalse(try database.isSeedComplete())
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

    func testFutureSchemaIsRejectedBeforeCreatingTablesOrWAL() throws {
        let path = NSTemporaryDirectory() + "future-findle-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        let connection = try XCTUnwrap(raw)
        try executeRawSQL(connection, "CREATE TABLE future_only (value TEXT); INSERT INTO future_only VALUES ('keep'); PRAGMA user_version = 999;")
        sqlite3_close(connection)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Database(path: path)) { XCTAssertTrue($0 is UnsupportedDatabaseSchemaError) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".initialization-lock"))
    }

    func testInitializationLockRejectsLinksWithoutTouchingTheirTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("database.db").path
        let privateFile = root.appendingPathComponent("keep.txt")
        try Data("keep original".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(atPath: path + ".initialization-lock", withDestinationPath: privateFile.path)
        XCTAssertThrowsError(try Database(path: path))
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "keep original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path + ".initialization-lock")
        try FileManager.default.linkItem(atPath: privateFile.path, toPath: path + ".initialization-lock")
        XCTAssertThrowsError(try Database(path: path))
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "keep original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFailedSchemaUpgradeRollsBackCreatedTablesAndVersion() throws {
        let path = NSTemporaryDirectory() + "migration-findle-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createVersion10Database(at: path)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        let connection = try XCTUnwrap(raw)
        defer { sqlite3_close(connection) }
        try executeRawSQL(connection, "CREATE TABLE system_metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL); CREATE TRIGGER reject_upgrade BEFORE INSERT ON system_metadata BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END;")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Database(path: path))
        XCTAssertEqual(try userVersion(at: path), 10)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        try executeRawSQL(connection, "DROP TRIGGER reject_upgrade")
        let upgraded = try Database(path: path)
        XCTAssertEqual(try userVersion(at: path), Int32(Database.schemaVersion))
        XCTAssertFalse(try upgraded.isSeedComplete())
    }

    func testOpeningCurrentSchemaDoesNotCompeteWithActiveDataWriter() throws {
        let committed = MoodleSite(id: "site-1", displayName: "Committed", baseURL: URL(string: "https://example.edu")!)
        try database.saveSite(committed)
        try database.execute("BEGIN IMMEDIATE")
        defer { try? database.execute("ROLLBACK") }
        try database.execute("UPDATE sites SET display_name = 'Uncommitted' WHERE id = 'site-1'")

        // A host/extension connection opening an already-current store needs no
        // migration write lock. Ordinary data writes must not make it fail.
        let newcomer = try Database(path: tempPath)
        XCTAssertEqual(try newcomer.fetchSite(id: committed.id)?.displayName, "Committed")
        XCTAssertEqual(try newcomer.currentChangeCounter(), try database.currentChangeCounter())
        try database.execute("COMMIT")
        XCTAssertEqual(try newcomer.fetchSite(id: committed.id)?.displayName, "Uncommitted")
    }

    func testConcurrentSchemaOpenersAgreeOnVersionAndReadiness() async throws {
        let path = NSTemporaryDirectory() + "concurrent-migration-\(UUID().uuidString).db"
        defer {
            for suffix in ["", "-wal", "-shm", ".initialization-lock"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try createVersion10Database(at: path)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let database = try Database(path: path)
                    return try database.isSeedComplete()
                }
            }
            for try await ready in group { XCTAssertFalse(ready) }
        }
        XCTAssertEqual(try userVersion(at: path), Int32(Database.schemaVersion))
    }

    func testConcurrentReadersReopenCheckpointedDatabaseWithoutWAL() async throws {
        // Some Apple SQLite versions retain empty WAL/SHM files on close.
        // Explicitly disable that policy for this disposable fixture so the
        // test actually exercises a checkpointed store with missing sidecars.
        database = nil
        do {
            var pointer: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(tempPath, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
            let connection = try XCTUnwrap(pointer)
            defer { XCTAssertEqual(sqlite3_close(connection), SQLITE_OK) }
            var persistWAL: Int32 = 0
            XCTAssertEqual(sqlite3_file_control(connection, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL), SQLITE_OK)
            try executeRawSQL(connection, "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath + "-shm"))
        let path = try XCTUnwrap(tempPath)
        for _ in 0..<10 {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let reader = try Database(path: path, readOnly: true)
                        return try reader.fetchAccounts().count
                    }
                }
                for try await count in group { XCTAssertEqual(count, 0) }
            }
        }
        database = try Database(path: path)
        XCTAssertEqual(try userVersion(at: path), Int32(Database.schemaVersion))
    }

    func testRecoverySnapshotIncludesWALAndRestoresAllCourseStateAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = MoodleSite(id: "site-1", displayName: "Site", baseURL: URL(string: "https://example.edu")!)
        try database.saveSite(site)
        let account = Account(id: "account", siteID: site.id, userID: 1, state: .authenticated(userID: 1), createdAt: Date(timeIntervalSince1970: 100))
        try database.saveAccount(account)
        try database.saveCourses([MoodleCourse(id: 1, shortName: "C1", fullName: "Course", siteID: site.id)])
        let current = makeItem(id: "current")
        let deleted = makeItem(id: "deleted")
        try database.saveItems([current, deleted])
        try database.deleteItemsWithTombstone(ids: [deleted.id])
        let cursor = SyncCursor(courseID: 1, siteID: site.id, lastSyncDate: Date(timeIntervalSince1970: 200), itemCount: 1)
        let outline = CourseOutlineSnapshot(courseID: 1, capturedAt: Date(timeIntervalSince1970: 300), sections: [CourseOutlineSection]())
        try database.saveSyncCursor(cursor)
        try database.saveCourseOutline(outline, siteID: site.id)
        try database.saveCourseTags([FinderTag(name: "Keep", color: .blue)], courseID: 1, siteID: site.id)
        try database.setSeedComplete(true)
        let snapshot = root.appendingPathComponent("snapshot.db")
        try database.writeRecoverySnapshot(to: snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        let destination = try Database(path: root.appendingPathComponent("destination.db").path)
        let old = makeItem(id: "previous")
        try destination.saveItems([old])
        try destination.setSeedComplete(true)
        let oldCounter = try destination.currentChangeCounter()
        try destination.execute("CREATE TRIGGER reject_seed BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT, 'injected seed failure'); END")
        XCTAssertThrowsError(try destination.restoreRecoverySnapshot(from: snapshot))
        XCTAssertEqual(try destination.fetchItems(courseID: 1, siteID: site.id), [old])
        XCTAssertEqual(try destination.currentChangeCounter(), oldCounter)
        XCTAssertTrue(try destination.isSeedComplete())
        try destination.execute("DROP TRIGGER reject_seed")
        let reader = try Database(path: destination.filePath, readOnly: true)
        try reader.execute("BEGIN DEFERRED")
        XCTAssertEqual(try reader.fetchItem(id: old.id), old)
        try destination.restoreRecoverySnapshot(from: snapshot)
        XCTAssertEqual(try reader.fetchItem(id: old.id), old)
        XCTAssertNil(try reader.fetchItem(id: current.id))
        try reader.execute("COMMIT")
        XCTAssertNil(try reader.fetchItem(id: old.id))
        XCTAssertEqual(try reader.fetchItem(id: current.id), current)
        XCTAssertEqual(try destination.fetchAccounts(), [account])
        XCTAssertEqual(try destination.fetchPendingDeletions(siteID: site.id), [deleted.id])
        XCTAssertEqual(try destination.fetchSyncCursor(courseID: 1, siteID: site.id), cursor)
        XCTAssertEqual(try destination.fetchCourseOutline(courseID: 1, siteID: site.id), outline)
        XCTAssertEqual(try destination.fetchCourseTags(courseID: 1, siteID: site.id).map(\.name), ["Keep"])
        XCTAssertTrue(try destination.isSeedComplete())
        try destination.verifyCompleteRecoveryState()
    }

    func testRecoveryContentionKeepsDestinationAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try database.saveItems([makeItem(id: "new-a"), makeItem(id: "new-b")])
        try database.setSeedComplete(true)
        let snapshot = root.appendingPathComponent("snapshot.db")
        try database.writeRecoverySnapshot(to: snapshot)
        let target = try Database(path: root.appendingPathComponent("destination.db").path)
        let previous = makeItem(id: "previous")
        try target.saveItems([previous])
        try target.setSeedComplete(true)
        let holder = try Database(path: target.filePath)
        try holder.execute("BEGIN IMMEDIATE")
        try target.execute("PRAGMA busy_timeout = 1")
        XCTAssertThrowsError(try target.restoreRecoverySnapshot(from: snapshot))
        XCTAssertEqual(try target.fetchAllItems(siteID: "site-1"), [previous])
        XCTAssertTrue(try target.isSeedComplete())
        try holder.execute("ROLLBACK")
        try target.restoreRecoverySnapshot(from: snapshot)
        XCTAssertNil(try target.fetchItem(id: previous.id))
        XCTAssertEqual(try target.fetchAllItems(siteID: "site-1").count, 2)
        try target.verifyCompleteRecoveryState()
    }

    func testKilledRecoveryWriterNeverPublishesPartialDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = MoodleSite(id: "site-1", displayName: "Recovered", baseURL: URL(string: "https://example.edu")!)
        try database.saveSite(site)
        try database.saveItems([makeItem(id: "new-a"), makeItem(id: "new-b")])
        try database.saveSyncCursor(SyncCursor(courseID: 1, siteID: site.id, lastSyncDate: Date(timeIntervalSince1970: 300), itemCount: 2))
        try database.setSeedComplete(true)
        let snapshot = root.appendingPathComponent("snapshot.db")
        try database.writeRecoverySnapshot(to: snapshot)
        let tables = ["sites", "accounts", "courses", "course_tags", "course_outlines", "items",
                      "sync_cursors", "assignments", "grade_items", "quizzes", "quiz_attempts",
                      "pending_deletions", "system_metadata"]
        for committed in [false, true] {
            let path = root.appendingPathComponent("destination-\(committed).db").path
            let target = try Database(path: path)
            let previous = makeItem(id: "previous")
            try target.saveItems([previous])
            try target.setSeedComplete(true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", path]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            // The injected-trigger regression exercises the actual API sequence;
            // this child process exercises crash recovery at its SQLite commit.
            let deleteSQL = tables.reversed().map { "DELETE FROM main.\($0);" }.joined(separator: "\n")
            let insertSQL = tables.map { "INSERT INTO main.\($0) SELECT * FROM recovery.\($0);" }.joined(separator: "\n")
            let quotedSnapshot = snapshot.path.replacingOccurrences(of: "'", with: "''")
            let sql = """
            .bail on
            .timeout 5000
            ATTACH DATABASE '\(quotedSnapshot)' AS recovery;
            BEGIN IMMEDIATE;
            \(deleteSQL)
            \(insertSQL)
            \(committed ? "COMMIT;" : "")
            .print ready

            """
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self), "ready\n")
            XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            try input.fileHandleForWriting.close()
            try output.fileHandleForReading.close()
            let reopened = try Database(path: path)
            if committed {
                XCTAssertNil(try reopened.fetchItem(id: previous.id))
                XCTAssertEqual(try reopened.fetchSite(id: site.id)?.displayName, "Recovered")
                XCTAssertEqual(try reopened.fetchAllItems(siteID: site.id).count, 2)
                XCTAssertEqual(try reopened.fetchSyncCursor(courseID: 1, siteID: site.id)?.itemCount, 2)
            } else {
                XCTAssertEqual(try reopened.fetchAllItems(siteID: site.id), [previous])
                XCTAssertNil(try reopened.fetchSite(id: site.id))
                XCTAssertNil(try reopened.fetchSyncCursor(courseID: 1, siteID: site.id))
            }
            try reopened.verifyCompleteRecoveryState()
            try reopened.restoreRecoverySnapshot(from: snapshot)
            XCTAssertEqual(try reopened.fetchAllItems(siteID: site.id).count, 2)
        }
    }

    func testRecoveryRejectsIncompleteSourcesExistingArtifactsAndNewerDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("snapshot.db")
        XCTAssertThrowsError(try database.writeRecoverySnapshot(to: snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        try database.saveItems([makeItem(id: "source")])
        try database.setSeedComplete(true)
        try database.writeRecoverySnapshot(to: snapshot)
        let original = try Data(contentsOf: snapshot)
        XCTAssertThrowsError(try database.writeRecoverySnapshot(to: snapshot))
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
        let target = try Database(path: root.appendingPathComponent("newer.db").path)
        try target.saveItems([makeItem(id: "new-a"), makeItem(id: "new-b"), makeItem(id: "new-c")])
        try target.setSeedComplete(true)
        let before = try target.fetchAllItems(siteID: "site-1")
        XCTAssertThrowsError(try target.restoreRecoverySnapshot(from: snapshot))
        XCTAssertEqual(try target.fetchAllItems(siteID: "site-1"), before)
        try target.execute("PRAGMA user_version = 999")
        XCTAssertThrowsError(try target.restoreRecoverySnapshot(from: snapshot)) { XCTAssertTrue($0 is UnsupportedDatabaseSchemaError) }
        XCTAssertEqual(try userVersion(at: target.filePath), 999)
        XCTAssertEqual(try target.fetchAllItems(siteID: "site-1"), before)
    }

    func testResetStaleDownloadsOnlyClearsDownloadingItems() throws {
        try database.saveItems([
            makeItem(id: "downloading-item"),
            makeItem(id: "materialized-item"),
        ])
        try database.updateItemSyncState(id: "downloading-item", state: .downloading)
        try database.updateItemSyncState(id: "materialized-item", state: .materialized)

        let resetCount = try database.resetStaleDownloads(siteID: "site-1")

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(try database.fetchItem(id: "downloading-item")?.syncState, .placeholder)
        // Items in other states must be left untouched.
        XCTAssertEqual(try database.fetchItem(id: "materialized-item")?.syncState, .materialized)
    }

    func testOpeningNewerSchemaIsRejectedWithoutChangingDatabase() throws {
        try database.saveItems([makeItem(id: "survives-reopen")])
        database = nil

        // A database last written by a newer binary must not be downgraded
        // when an older binary (this one) opens it.
        let newerVersion = Int32(Database.schemaVersion + 1)
        try setUserVersion(newerVersion, at: tempPath)

        let bytes = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        XCTAssertThrowsError(try Database(path: tempPath))
        XCTAssertThrowsError(try Database(path: tempPath, readOnly: true))
        XCTAssertEqual(try userVersion(at: tempPath), newerVersion)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tempPath)), bytes)
    }

    func testReopeningCurrentSchemaIsNoOp() throws {
        try database.saveItems([makeItem(id: "stable-item")])
        let counterBefore = try database.currentChangeCounter()
        database = nil

        database = try Database(path: tempPath)

        XCTAssertEqual(try userVersion(at: tempPath), Int32(Database.schemaVersion))
        XCTAssertEqual(try database.currentChangeCounter(), counterBefore)
        XCTAssertNotNil(try database.fetchItem(id: "stable-item"))
    }

    func testDeleteItemAndChildrenWritesTombstonesAndReturnsLocalPaths() throws {
        let folder = LocalItem(id: "local-folder", siteID: "site-1", courseID: 1, remoteID: 0, filename: "Notes", isDirectory: true, isLocal: true)
        let file = LocalItem(id: "local-file", parentID: folder.id, siteID: "site-1", courseID: 1, remoteID: 0, filename: "a.txt", isLocal: true)
        let untouched = makeItem(id: "untouched-item")
        try database.saveItems([folder, file, untouched])
        try database.updateItemSyncState(id: file.id, state: .materialized, localPath: "/test/local/a.txt")

        let anchor = try database.currentChangeCounter()
        let localPaths = try database.deleteItemAndChildren(id: folder.id)

        XCTAssertEqual(localPaths, ["/test/local/a.txt"])
        XCTAssertNil(try database.fetchItem(id: folder.id))
        XCTAssertNil(try database.fetchItem(id: file.id))
        XCTAssertNotNil(try database.fetchItem(id: untouched.id))
        XCTAssertEqual(
            Set(try database.fetchPendingDeletionsSince(anchor: anchor, siteID: "site-1", through: nil)),
            Set([folder.id, file.id])
        )
        XCTAssertGreaterThan(try database.currentChangeCounter(), anchor)
    }

    func testDeleteAllDataPreservesChangeCounter() throws {
        try database.saveItems([makeItem(id: "counted-item")])
        let before = try database.currentChangeCounter()
        XCTAssertGreaterThan(before, 0)

        try database.deleteAllData()

        XCTAssertEqual(try database.currentChangeCounter(), before)
    }

    private func userVersion(at path: String) throws -> Int32 {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        guard let db else {
            throw NSError(domain: "DatabaseTests", code: 1)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }

    private func setUserVersion(_ version: Int32, at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        guard let db else {
            throw NSError(domain: "DatabaseTests", code: 1)
        }
        defer { sqlite3_close(db) }
        try executeRawSQL(db, "PRAGMA user_version = \(version)")
    }

    private func makeItem(id: String, parentID: String? = nil, courseID: Int = 1, siteID: String = "site-1") -> LocalItem {
        LocalItem(
            id: id,
            parentID: parentID,
            siteID: siteID,
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

    func testFetchItemsChangedSinceCanBeBoundToCapturedCounter() throws {
        try database.saveItems([makeItem(id: "old-1")])
        let anchor = try database.currentChangeCounter()
        try database.saveItems([makeItem(id: "new-1")])
        let upperBound = try database.currentChangeCounter()
        try database.saveItems([makeItem(id: "late-1")])

        let changed = try database.fetchItemsChangedSince(anchor: anchor, siteID: "site-1", through: upperBound)
        XCTAssertEqual(Set(changed.map(\.id)), Set(["new-1"]))
    }

    func testPreservingChangeCounterKeepsRestoredRowsAfterExistingAnchor() throws {
        try database.saveItems([makeItem(id: "before-reset")])
        let oldAnchor = try database.currentChangeCounter()

        try database.deleteAllData()
        try database.preserveChangeCounter(atLeast: oldAnchor)
        try database.saveItems([makeItem(id: "restored")])

        let changed = try database.fetchItemsChangedSince(anchor: oldAnchor, siteID: "site-1")
        XCTAssertEqual(changed.map(\.id), ["restored"])
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

    func testPendingDeletionsAreScopedBySite() throws {
        try database.saveItems([
            makeItem(id: "site-a-item", siteID: "site-a"),
            makeItem(id: "site-b-item", siteID: "site-b"),
        ])

        try database.deleteItemsWithTombstone(ids: ["site-a-item", "site-b-item"])

        let anchor: Int64 = 0
        XCTAssertEqual(
            try database.fetchPendingDeletionsSince(anchor: anchor, siteID: "site-a", through: nil),
            ["site-a-item"]
        )
        XCTAssertEqual(
            try database.fetchPendingDeletions(siteID: "site-b"),
            ["site-b-item"]
        )
    }

    func testReintroducedItemClearsItsOldTombstone() throws {
        try database.saveItems([makeItem(id: "reintroduced")])
        let anchor = try database.currentChangeCounter()

        try database.deleteItemsWithTombstone(ids: ["reintroduced"])
        try database.saveItems([makeItem(id: "reintroduced")])

        XCTAssertTrue(try database.fetchPendingDeletionsSince(anchor: anchor).isEmpty)
    }

    private func makeDirectory(id: String, parentID: String? = nil, courseID: Int = 1, isLocal: Bool = false) -> LocalItem {
        LocalItem(
            id: id,
            parentID: parentID,
            siteID: "site-1",
            courseID: courseID,
            remoteID: 0,
            filename: id,
            isDirectory: true,
            isLocal: isLocal
        )
    }

    func testRemoteDeletionKeepsAncestorsOfLocalFilesAndDeletesRemoteSiblings() throws {
        let course = makeDirectory(id: "remote-course")
        let sectionWithLocal = makeDirectory(id: "remote-section-a", parentID: course.id)
        let localFile = LocalItem(id: "local-note", parentID: sectionWithLocal.id, siteID: "site-1", courseID: 1, remoteID: 0, filename: "note.txt", isLocal: true)
        let remoteSibling = makeItem(id: "remote-file-sibling", parentID: sectionWithLocal.id)
        let emptySection = makeDirectory(id: "remote-section-b", parentID: course.id)
        let emptySectionFile = makeItem(id: "remote-file-b", parentID: emptySection.id)
        try database.saveItems([course, sectionWithLocal, localFile, remoteSibling, emptySection, emptySectionFile])

        try database.deleteItemsWithTombstone(ids: [course.id])

        XCTAssertNotNil(try database.fetchItem(id: course.id))
        XCTAssertNotNil(try database.fetchItem(id: sectionWithLocal.id))
        XCTAssertEqual(try database.fetchItem(id: localFile.id)?.parentID, sectionWithLocal.id)
        XCTAssertNil(try database.fetchItem(id: remoteSibling.id))
        XCTAssertNil(try database.fetchItem(id: emptySection.id))
        XCTAssertNil(try database.fetchItem(id: emptySectionFile.id))
        XCTAssertEqual(
            Set(try database.fetchPendingDeletions()),
            Set([remoteSibling.id, emptySection.id, emptySectionFile.id])
        )
    }

    func testPruneDirectoriesWithoutLocalContentRemovesBottomUpAndKeepsLocalPaths() throws {
        // Course 1 keeps a path to a user file. Its other section has only remote content.
        let keepCourse = makeDirectory(id: "course-keep", courseID: 1)
        let keepSection = makeDirectory(id: "section-keep", parentID: keepCourse.id, courseID: 1)
        let localNote = LocalItem(id: "local-note", parentID: keepSection.id, siteID: "site-1", courseID: 1, remoteID: 0, filename: "note.txt", isLocal: true)
        let dropSection = makeDirectory(id: "section-drop", parentID: keepCourse.id, courseID: 1)
        let dropFile = makeItem(id: "file-drop", parentID: dropSection.id, courseID: 1)

        // Course 2 has no local content anywhere, so the course root must go too.
        let dropCourse = makeDirectory(id: "course-drop", courseID: 2)
        let dropStandIn = makeDirectory(id: "section-drop-2", parentID: dropCourse.id, courseID: 2, isLocal: true)

        // Course 3 is not in the pruned set and must not be touched.
        let otherCourse = makeDirectory(id: "course-other", courseID: 3)

        try database.saveItems([keepCourse, keepSection, localNote, dropSection, dropFile, dropCourse, dropStandIn, otherCourse])

        let removed = try database.pruneDirectoriesWithoutLocalContent(courseIDs: [1, 2], siteID: "site-1")

        XCTAssertEqual(removed, 4)
        XCTAssertNotNil(try database.fetchItem(id: keepCourse.id))
        XCTAssertNotNil(try database.fetchItem(id: keepSection.id))
        XCTAssertNotNil(try database.fetchItem(id: localNote.id))
        XCTAssertNotNil(try database.fetchItem(id: otherCourse.id))
        XCTAssertNil(try database.fetchItem(id: dropSection.id))
        XCTAssertNil(try database.fetchItem(id: dropFile.id))
        XCTAssertNil(try database.fetchItem(id: dropCourse.id))
        XCTAssertNil(try database.fetchItem(id: dropStandIn.id))
        XCTAssertEqual(
            Set(try database.fetchPendingDeletions(siteID: "site-1")),
            Set([dropSection.id, dropFile.id, dropCourse.id, dropStandIn.id])
        )
    }

    func testUpdateLocalPathsRewritesOnlyMatchingPrefixes() throws {
        let folder = LocalItem(id: "local-folder", siteID: "site-1", courseID: 1, remoteID: 0, filename: "b", isDirectory: true, isLocal: true)
        let nested = LocalItem(id: "local-nested", parentID: folder.id, siteID: "site-1", courseID: 1, remoteID: 0, filename: "c.txt", isLocal: true)
        let sibling = LocalItem(id: "local-sibling", siteID: "site-1", courseID: 1, remoteID: 0, filename: "d.txt", isLocal: true)
        let remote = makeItem(id: "remote-under-prefix")
        let otherSite = LocalItem(id: "local-other-site", siteID: "site-2", courseID: 1, remoteID: 0, filename: "e.txt", isLocal: true)
        try database.saveItems([folder, nested, sibling, remote, otherSite])
        try database.updateItemSyncState(id: folder.id, state: .materialized, localPath: "/a/b")
        try database.updateItemSyncState(id: nested.id, state: .materialized, localPath: "/a/b/c.txt")
        try database.updateItemSyncState(id: sibling.id, state: .materialized, localPath: "/a/bc/d.txt")
        try database.updateItemSyncState(id: remote.id, state: .materialized, localPath: "/a/b/remote.txt")
        try database.updateItemSyncState(id: otherSite.id, state: .materialized, localPath: "/a/b/e.txt")

        let anchor = try database.currentChangeCounter()
        let changed = try database.updateLocalPaths(fromPrefix: "/a/b", toPrefix: "/x/y", siteID: "site-1")

        XCTAssertEqual(changed, 2)
        XCTAssertEqual(try database.fetchItem(id: folder.id)?.localPath, "/x/y")
        XCTAssertEqual(try database.fetchItem(id: nested.id)?.localPath, "/x/y/c.txt")
        XCTAssertEqual(try database.fetchItem(id: sibling.id)?.localPath, "/a/bc/d.txt")
        XCTAssertEqual(try database.fetchItem(id: remote.id)?.localPath, "/a/b/remote.txt")
        XCTAssertEqual(try database.fetchItem(id: otherSite.id)?.localPath, "/a/b/e.txt")
        XCTAssertEqual(
            Set(try database.fetchItemsChangedSince(anchor: anchor, siteID: "site-1").map(\.id)),
            Set([folder.id, nested.id])
        )
    }

    func testFetchLocalItemsReturnsOnlyLocalRowsForSite() throws {
        let note = LocalItem(id: "local-note", siteID: "site-1", courseID: 1, remoteID: 0, filename: "note.txt", isLocal: true)
        let standIn = makeDirectory(id: "section-standin", courseID: 1, isLocal: true)
        let remote = makeItem(id: "remote-file")
        let otherSite = LocalItem(id: "local-other", siteID: "site-2", courseID: 1, remoteID: 0, filename: "other.txt", isLocal: true)
        try database.saveItems([note, standIn, remote, otherSite])

        let fetched = try database.fetchLocalItems(siteID: "site-1")

        XCTAssertEqual(Set(fetched.map(\.id)), Set([note.id, standIn.id]))
        XCTAssertTrue(fetched.allSatisfy(\.isLocal))
    }

    func testDeleteLocalItemsRemovesSubtreesWithTombstonesAndIgnoresMissingIDs() throws {
        let folder = LocalItem(id: "local-folder", siteID: "site-1", courseID: 1, remoteID: 0, filename: "Notes", isDirectory: true, isLocal: true)
        let file = LocalItem(id: "local-file", parentID: folder.id, siteID: "site-1", courseID: 1, remoteID: 0, filename: "a.txt", isLocal: true)
        let untouched = makeItem(id: "untouched-item")
        try database.saveItems([folder, file, untouched])

        try database.deleteLocalItems(ids: [folder.id, "missing-id"])

        XCTAssertNil(try database.fetchItem(id: folder.id))
        XCTAssertNil(try database.fetchItem(id: file.id))
        XCTAssertNotNil(try database.fetchItem(id: untouched.id))
        XCTAssertEqual(Set(try database.fetchPendingDeletions(siteID: "site-1")), Set([folder.id, file.id]))
    }
}
