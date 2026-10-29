// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain
@testable import FindleNetworking
@testable import FindlePersistence
@testable import FindleSyncEngine

final class SyncEngineCourseScopeTests: XCTestCase {
    var database: Database!
    var tempPath: String!

    override func setUp() async throws {
        tempPath = NSTemporaryDirectory() + "findle_sync_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testIncompleteMoodleResponsesKeepLastSuccessfulCourseSnapshot() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        let valid = #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"type":"file","filename":"keep.pdf","filesize":20}]}]}]"#
        try await engine(snapshot: valid).syncCourse(site: site, token: token, course: course)
        let priorItems = try database.fetchItems(courseID: course.id, siteID: site.id)
        let priorCursor = try XCTUnwrap(database.fetchSyncCursor(courseID: course.id, siteID: site.id))
        let priorOutline = try XCTUnwrap(database.fetchCourseOutline(courseID: course.id, siteID: site.id))
        let priorCounter = try database.currentChangeCounter()
        XCTAssertEqual(priorItems.count, 3)

        let malformed = [
            #"[{"id":"bad","section":1,"modules":[]}]"#,
            #"[{"id":10,"section":1,"modules":[{"id":"bad","modname":"resource"}]}]"#,
            #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"filename":42}]}]}]"#,
            #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"type":"file"}]}]}]"#,
            #"[{"id":10,"section":1,"modules":[{"id":301}]}]"#,
            #"[{"id":10,"section":1,"modules":["#,
        ]
        for snapshot in malformed {
            do {
                try await engine(snapshot: snapshot).syncCourse(site: site, token: token, course: course)
                XCTFail("Incomplete response was published: \(snapshot)")
            } catch {
                XCTAssertEqual(try database.fetchItems(courseID: course.id, siteID: site.id), priorItems)
                XCTAssertEqual(try database.fetchSyncCursor(courseID: course.id, siteID: site.id), priorCursor)
                XCTAssertEqual(try database.fetchCourseOutline(courseID: course.id, siteID: site.id), priorOutline)
                XCTAssertEqual(try database.currentChangeCounter(), priorCounter)
                XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
            }
        }

        // An explicitly complete response may remove remote files. Personal
        // files and their original remote parent directories still survive.
        let section = try XCTUnwrap(priorItems.first { $0.id.hasPrefix("section-") })
        let personalFile = LocalItem(id: "personal-note", parentID: section.id, siteID: site.id,
                                     courseID: course.id, remoteID: 0, filename: "Notes.txt", isLocal: true)
        try database.saveItems([personalFile])
        try await engine(snapshot: "[]").syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try database.fetchItem(id: personalFile.id), personalFile)
        XCTAssertNotNil(try database.fetchItem(id: section.id))
        let remoteFile = try XCTUnwrap(priorItems.first { !$0.isDirectory })
        XCTAssertNil(try database.fetchItem(id: remoteFile.id))
        XCTAssertEqual(try database.fetchPendingDeletions(), [remoteFile.id])
        XCTAssertEqual(try database.fetchCourseOutline(courseID: course.id, siteID: site.id)?.sections, [])
        XCTAssertEqual(try database.fetchSyncCursor(courseID: course.id, siteID: site.id)?.itemCount, 1)
    }

    func testURLResourceMaterializesLocalPlistWithExactSizeAndNoProviderDownload() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C", fullName: "Course", siteID: site.id)
        let externalURL = URL(string: "https://external.test/article?one=1&two=2")!
        let provider = FakeLMSProvider(courseContents: [course.id: [
            MoodleSection(id: 11, courseID: course.id, name: "Week", sectionNumber: 1, modules: [
                MoodleModule(id: 501, name: "Reading", modName: "url", contents: [
                    MoodleFileContent(type: "url", fileName: "Reading", fileURL: externalURL)
                ])
            ])
        ]], onDownload: { _, _, _, _ in XCTFail("A URL resource reached the credential-bearing provider") })
        let engine = SyncEngine(provider: provider, database: database)
        try await engine.syncCourse(site: site, token: AuthToken(token: "fixture-secret"), course: course)
        let item = try XCTUnwrap(database.fetchItem(id: "url-site-1-101-501"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await engine.downloadItem(itemID: item.id, site: site, token: AuthToken(token: "fixture-secret"), destination: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Int64(data.count), item.fileSize)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                       ["URL": externalURL.absoluteString])
        XCTAssertEqual(try database.fetchItem(id: item.id)?.syncState, .materialized)
    }

    func testDownloadRejectsWrongSiteAndUntrustedOrdinaryWeblocBeforeProvider() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let provider = FakeLMSProvider(courseContents: [:], onDownload: { _, _, _, _ in XCTFail("Rejected item reached provider") })
        let engine = SyncEngine(provider: provider, database: database)
        let items = [
            LocalItem(id: "file-wrong-site", siteID: "site-2", courseID: 1, remoteID: 1, filename: "file.pdf",
                      remoteURL: URL(string: "https://moodle.example.edu/file")),
            LocalItem(id: "file-site-1-1-1-Reading.webloc", siteID: site.id, courseID: 1, remoteID: 1, filename: "Reading.webloc",
                      contentType: "com.apple.web-internet-location", remoteURL: URL(string: "https://external.test/file"))
        ]
        try database.saveItems(items)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for item in items {
            do {
                try await engine.downloadItem(itemID: item.id, site: site, token: AuthToken(token: "fixture-secret"), destination: destination)
                XCTFail("Untrusted item accepted")
            } catch {}
            XCTAssertEqual(try database.fetchItem(id: item.id), item)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testLateDownloadDoesNotPublishOverNewItemVersion() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let old = LocalItem(id: "file-site-1-1-1", siteID: site.id, courseID: 1, remoteID: 1, filename: "file.pdf",
                            remoteURL: URL(string: "https://moodle.example.edu/file"), contentVersion: "old")
        var replacement = old
        replacement.contentVersion = "new"
        let newItem = replacement
        let capturedDatabase = try XCTUnwrap(database)
        try capturedDatabase.saveItems([old])
        let provider = FakeLMSProvider(courseContents: [:], onDownload: { _, suppliedSite, _, destination in
            XCTAssertEqual(suppliedSite.id, site.id)
            try capturedDatabase.saveItems([newItem])
            try Data("old response".utf8).write(to: destination)
        })
        let engine = SyncEngine(provider: provider, database: capturedDatabase)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await engine.downloadItem(itemID: old.id, site: site, token: AuthToken(token: "fixture-secret"), destination: destination)
            XCTFail("Stale download was published")
        } catch {}
        XCTAssertEqual(try capturedDatabase.fetchItem(id: old.id), newItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellationAfterFetchingKeepsWholePreviousRevision() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        let valid = #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"filename":"keep.pdf"}]}]}]"#
        try await engine(snapshot: valid).syncCourse(site: site, token: token, course: course)
        let priorItems = try database.fetchItems(courseID: course.id, siteID: site.id)
        let priorCursor = try database.fetchSyncCursor(courseID: course.id, siteID: site.id)
        let priorOutline = try database.fetchCourseOutline(courseID: course.id, siteID: site.id)
        let priorCounter = try database.currentChangeCounter()
        let provider = FakeLMSProvider(courseContents: [:], cancelBeforeReturning: true)
        let cancelledEngine = SyncEngine(provider: provider, database: database)
        do {
            try await cancelledEngine.syncCourse(site: site, token: token, course: course)
            XCTFail("Cancelled fetch should not publish an empty course")
        } catch is CancellationError {
            XCTAssertEqual(try database.fetchItems(courseID: course.id, siteID: site.id), priorItems)
            XCTAssertEqual(try database.fetchSyncCursor(courseID: course.id, siteID: site.id), priorCursor)
            XCTAssertEqual(try database.fetchCourseOutline(courseID: course.id, siteID: site.id), priorOutline)
            XCTAssertEqual(try database.currentChangeCounter(), priorCounter)
            XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
        }
    }

    private func engine(snapshot: String) -> SyncEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CourseSnapshotURLProtocol.self]
        // The fixture travels with each request: concurrent tests need no shared mutable handler.
        configuration.httpAdditionalHeaders = ["X-Test-Course-Snapshot": snapshot]
        let client = MoodleClient(session: URLSession(configuration: configuration))
        return SyncEngine(provider: client, database: database)
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

    func testFolderFilesWithSameNameInDifferentSubfoldersGetDistinctItems() async throws {
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
        let folderContents = [
            MoodleFileContent(
                type: "file",
                fileName: "index.html",
                filePath: "/a/",
                fileURL: URL(string: "https://moodle.example.edu/pluginfile.php/a/index.html")
            ),
            MoodleFileContent(
                type: "file",
                fileName: "index.html",
                filePath: "/b/",
                fileURL: URL(string: "https://moodle.example.edu/pluginfile.php/b/index.html")
            ),
            MoodleFileContent(
                type: "file",
                fileName: "readme.txt",
                filePath: "/",
                fileURL: URL(string: "https://moodle.example.edu/pluginfile.php/readme.txt")
            ),
        ]
        let provider = FakeLMSProvider(courseContents: [
            course.id: [
                MoodleSection(
                    id: 11,
                    courseID: course.id,
                    name: "Week 1",
                    sectionNumber: 1,
                    modules: [
                        MoodleModule(
                            id: 501,
                            name: "Pages",
                            modName: ResourceType.folder.rawValue,
                            contents: folderContents
                        ),
                    ]
                ),
            ],
        ])
        let engine = SyncEngine(provider: provider, database: database)

        try await engine.syncCourse(site: site, token: token, course: course)

        let folderItems = try database.fetchItems(parentID: "folder-\(site.id)-\(course.id)-501")
        XCTAssertEqual(folderItems.count, 3)
        XCTAssertEqual(Set(folderItems.map(\.id)).count, 3)
        XCTAssertEqual(Set(folderItems.map(\.filename)), ["index (a).html", "index (b).html", "readme.txt"])
        // Root-level files keep the ID they had before subdirectory paths were included.
        XCTAssertNotNil(try database.fetchItem(id: "file-\(site.id)-\(course.id)-501-readme.txt"))
    }

    func testFilenameOnlyChangeKeepsMaterializedFile() async throws {
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
        let modifiedDate = Date(timeIntervalSince1970: 1_000)
        let fileID = "file-\(site.id)-\(course.id)-301-notes.pdf"

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
                id: fileID,
                parentID: "section-\(site.id)-\(course.id)-11",
                siteID: site.id,
                courseID: course.id,
                remoteID: 301,
                filename: "Notes.pdf",
                isDirectory: false,
                fileSize: 200,
                syncState: .materialized,
                localPath: "/tmp/notes.pdf",
                contentVersion: String(Int(modifiedDate.timeIntervalSince1970))
            ),
        ])

        // Same remote file, same size and version, but the display name now differs.
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

        let refreshedItem = try XCTUnwrap(database.fetchItem(id: fileID))
        XCTAssertEqual(refreshedItem.filename, "notes.pdf")
        XCTAssertEqual(refreshedItem.syncState, .materialized)
        XCTAssertEqual(refreshedItem.localPath, "/tmp/notes.pdf")
    }
}

private struct FakeLMSProvider: LMSProvider {
    let courseContents: [Int: [MoodleSection]]
    var cancelBeforeReturning = false
    var onDownload: @Sendable (URL, MoodleSite, AuthToken, URL) async throws -> Void = { _, _, _, _ in }

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
        if cancelBeforeReturning {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return courseContents[courseID] ?? []
    }

    func downloadFile(url: URL, site: MoodleSite, token: AuthToken, destination: URL) async throws {
        try await onDownload(url, site, token, destination)
    }

    func authenticatedFileRequest(fileURL: URL, site: MoodleSite, token: AuthToken) throws -> URLRequest {
        URLRequest(url: fileURL)
    }
}

private final class CourseSnapshotURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let snapshot = request.value(forHTTPHeaderField: "X-Test-Course-Snapshot"),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(snapshot.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
