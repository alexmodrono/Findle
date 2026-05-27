// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain
@testable import FoodleNetworking
@testable import FoodlePersistence
@testable import FoodleSyncEngine

final class SyncEngineCourseScopeTests: XCTestCase {
    var database: Database!
    var tempPath: String!

    override func setUp() async throws {
        tempPath = NSTemporaryDirectory() + "foodle_sync_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testSyncCourseOnlyDiffsItemsFromCurrentCourse() async throws {
        let site = MoodleSite(
            id: "site-1",
            displayName: "Example",
            baseURL: URL(string: "https://moodle.example.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true
            )
        )
        let token = AuthToken(token: "token")
        let syncedCourse = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let untouchedCourse = MoodleCourse(id: 202, shortName: "C202", fullName: "Course 202", siteID: site.id)

        let syncedCourseRoot = LocalItem(
            id: "course-\(site.id)-\(syncedCourse.id)",
            parentID: nil,
            siteID: site.id,
            courseID: syncedCourse.id,
            remoteID: syncedCourse.id,
            filename: syncedCourse.effectiveFolderName,
            isDirectory: true,
            syncState: .materialized
        )
        let staleCourseItem = LocalItem(
            id: "file-\(site.id)-\(syncedCourse.id)-301-old.pdf",
            parentID: syncedCourseRoot.id,
            siteID: site.id,
            courseID: syncedCourse.id,
            remoteID: 301,
            filename: "old.pdf",
            isDirectory: false,
            syncState: .materialized
        )
        let untouchedCourseRoot = LocalItem(
            id: "course-\(site.id)-\(untouchedCourse.id)",
            parentID: nil,
            siteID: site.id,
            courseID: untouchedCourse.id,
            remoteID: untouchedCourse.id,
            filename: untouchedCourse.effectiveFolderName,
            isDirectory: true,
            syncState: .materialized
        )
        let untouchedCourseItem = LocalItem(
            id: "file-\(site.id)-\(untouchedCourse.id)-401-keep.pdf",
            parentID: untouchedCourseRoot.id,
            siteID: site.id,
            courseID: untouchedCourse.id,
            remoteID: 401,
            filename: "keep.pdf",
            isDirectory: false,
            syncState: .materialized
        )

        try database.saveItems([
            syncedCourseRoot,
            staleCourseItem,
            untouchedCourseRoot,
            untouchedCourseItem,
        ])

        let provider = FakeLMSProvider(courseContents: [syncedCourse.id: []])
        let engine = SyncEngine(provider: provider, database: database)

        try await engine.syncCourse(site: site, token: token, course: syncedCourse)

        let refreshedSyncedRoot = try XCTUnwrap(database.fetchItem(id: syncedCourseRoot.id))
        let refreshedUntouchedRoot = try XCTUnwrap(database.fetchItem(id: untouchedCourseRoot.id))
        let refreshedUntouchedItem = try XCTUnwrap(database.fetchItem(id: untouchedCourseItem.id))

        // Stale items in the synced course should be deleted (not downgraded
        // to .placeholder) and recorded in pending_deletions so the File
        // Provider extension can report the deletion to Finder.
        XCTAssertNil(try database.fetchItem(id: staleCourseItem.id))
        let pendingDeletions = try database.fetchPendingDeletions()
        XCTAssertTrue(pendingDeletions.contains(staleCourseItem.id))

        XCTAssertEqual(refreshedSyncedRoot.syncState, .materialized)
        XCTAssertEqual(refreshedUntouchedRoot.syncState, .materialized)
        XCTAssertEqual(refreshedUntouchedItem.syncState, .materialized)
        // Items belonging to other courses must not be tombstoned by this sync.
        XCTAssertFalse(pendingDeletions.contains(untouchedCourseItem.id))
    }

    func testSyncCoursePreservesItemTagDataWhenRemoteFileChanges() async throws {
        let site = MoodleSite(
            id: "site-1",
            displayName: "Example",
            baseURL: URL(string: "https://moodle.example.edu")!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true
            )
        )
        let token = AuthToken(token: "token")
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let tagData = FinderTag.tagData(from: [FinderTag(name: "Read later", color: .blue)])
        let modifiedDate = Date(timeIntervalSince1970: 2_000)

        try database.saveItems([
            LocalItem(
                id: "course-\(site.id)-\(course.id)",
                parentID: nil,
                siteID: site.id,
                courseID: course.id,
                remoteID: course.id,
                filename: course.effectiveFolderName,
                isDirectory: true,
                syncState: .materialized
            ),
            LocalItem(
                id: "section-\(site.id)-\(course.id)-11",
                parentID: "course-\(site.id)-\(course.id)",
                siteID: site.id,
                courseID: course.id,
                remoteID: 11,
                filename: "Week 1",
                isDirectory: true,
                syncState: .materialized
            ),
            LocalItem(
                id: "file-\(site.id)-\(course.id)-301-notes.pdf",
                parentID: "section-\(site.id)-\(course.id)-11",
                siteID: site.id,
                courseID: course.id,
                remoteID: 301,
                filename: "notes.pdf",
                isDirectory: false,
                fileSize: 100,
                syncState: .materialized,
                contentVersion: "1000",
                tagData: tagData
            ),
        ])

        let provider = FakeLMSProvider(courseContents: [
            course.id: [
                MoodleSection(
                    id: 11,
                    courseID: course.id,
                    name: "Week 1",
                    sectionNumber: 1,
                    modules: [
                        MoodleModule(
                            id: 301,
                            name: "Notes",
                            modName: ResourceType.file.rawValue,
                            contents: [
                                MoodleFileContent(
                                    type: "file",
                                    fileName: "notes.pdf",
                                    fileSize: 200,
                                    fileURL: URL(string: "https://moodle.example.edu/pluginfile.php/notes.pdf"),
                                    timeModified: modifiedDate,
                                    mimeType: "application/pdf"
                                ),
                            ]
                        ),
                    ]
                ),
            ],
        ])
        let engine = SyncEngine(provider: provider, database: database)

        try await engine.syncCourse(site: site, token: token, course: course)

        let refreshedItem = try XCTUnwrap(database.fetchItem(id: "file-\(site.id)-\(course.id)-301-notes.pdf"))
        XCTAssertEqual(refreshedItem.fileSize, 200)
        XCTAssertEqual(refreshedItem.contentVersion, String(Int(modifiedDate.timeIntervalSince1970)))
        XCTAssertEqual(refreshedItem.tagData, tagData)
    }
}

private struct FakeLMSProvider: LMSProvider {
    let courseContents: [Int: [MoodleSection]]

    func validateSite(url: URL) async throws -> MoodleSite {
        MoodleSite(displayName: url.host ?? "Test", baseURL: url)
    }

    func authenticate(site: MoodleSite, username: String, password: String) async throws -> AuthToken {
        AuthToken(token: "test-token")
    }

    func parseTokenFromSSOCallback(callbackURLString: String, site: MoodleSite, passport: String) throws -> AuthToken {
        AuthToken(token: "test-token")
    }

    func fetchUserInfo(site: MoodleSite, token: AuthToken) async throws -> MoodleUser {
        MoodleUser(id: 1, username: "test", fullName: "Test User", siteID: site.id)
    }

    func fetchCourses(site: MoodleSite, token: AuthToken, userID: Int) async throws -> [MoodleCourse] {
        []
    }

    func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection] {
        courseContents[courseID] ?? []
    }

    func downloadFile(url: URL, token: AuthToken, destination: URL) async throws {}

    func authenticatedFileURL(fileURL: URL, token: AuthToken) -> URL {
        fileURL
    }
}
