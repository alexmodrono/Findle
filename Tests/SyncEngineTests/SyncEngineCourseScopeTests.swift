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

    func testDownloadPreservesOriginalFailureWhenRecordingErrorStateFails() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let item = LocalItem(id: "file-site-1-1-1", siteID: site.id, courseID: 1, remoteID: 1, filename: "file.pdf",
                             remoteURL: URL(string: "https://moodle.example.edu/file"))
        try database.saveItems([item])
        try database.execute("""
            CREATE TRIGGER reject_download_error BEFORE UPDATE OF sync_state ON items
            WHEN NEW.sync_state = 'error'
            BEGIN SELECT RAISE(ABORT, 'fixture state write failure'); END;
            """)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }

        let failures: [FindleError] = [.tokenExpired, .networkUnavailable, .requestFailed(statusCode: 503, detail: "fixture")]
        for failure in failures {
            let provider = FakeLMSProvider(courseContents: [:], onDownload: { _, _, _, destination in
                try Data("partial response".utf8).write(to: destination)
                throw failure
            })
            let engine = SyncEngine(provider: provider, database: database)
            do {
                try await engine.downloadItem(itemID: item.id, site: site, token: AuthToken(token: "fixture-secret"), destination: destination)
                XCTFail("Download failure was lost")
            } catch {
                XCTAssertEqual(DiagnosticFailure(error).kind, DiagnosticFailure(failure).kind)
                XCTAssertEqual((error as? FindleError)?.requiresReauthentication, failure.requiresReauthentication)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try database.fetchItem(id: item.id)?.syncState, .downloading)
        }
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

    /// Without `assignments`, Moodle refuses mod_assign_get_assignments.
    private func engine(snapshot: String, assignments: String? = nil) -> SyncEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CourseSnapshotURLProtocol.self]
        // The fixture travels with each request: concurrent tests need no shared mutable handler.
        var headers = ["X-Test-Course-Snapshot": snapshot]
        if let assignments { headers["X-Test-Assignments"] = assignments }
        configuration.httpAdditionalHeaders = headers
        let client = MoodleClient(session: URLSession(configuration: configuration))
        return SyncEngine(provider: client, database: database)
    }

    func testAssignmentsBecomeFoldersAndLabelsBecomeASectionReadme() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        let withLabel = #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"type":"file","filename":"notes.pdf","filesize":20}]},{"id":401,"name":"Essay 1","modname":"assign"},{"id":501,"modname":"label","description":"<p>Bring a <b>laptop</b> &amp; charger</p>"}]}]"#
        let assignments = #"{"courses":[{"id":101,"assignments":[{"id":9,"cmid":401,"course":101,"name":"Essay 1","intro":"<p>Write 500 words.</p>","introattachments":[{"filename":"rubric.pdf","filepath":"/","filesize":10,"fileurl":"https://moodle.example.edu/webservice/pluginfile.php/1/mod_assign/intro/rubric.pdf","timemodified":5,"mimetype":"application/pdf"}]}]}]}"#
        func text(_ id: String) throws -> String? {
            try database.fetchGeneratedContent(itemID: id).map { String(decoding: $0, as: UTF8.self) }
        }

        try await engine(snapshot: withLabel, assignments: assignments).syncCourse(site: site, token: token, course: course)
        let section = "section-site-1-101-10", folder = "assign-site-1-101-401"
        let assignment = try XCTUnwrap(database.fetchItem(id: folder))
        XCTAssertEqual(assignment.filename, "Essay 1")
        XCTAssertTrue(assignment.isDirectory)
        XCTAssertEqual(assignment.parentID, section)
        let contents = try database.fetchItems(parentID: folder, siteID: site.id)
        XCTAssertEqual(Set(contents.map(\.filename)), ["rubric.pdf", "README.md"])
        XCTAssertNotNil(contents.first { $0.filename == "rubric.pdf" }?.remoteURL)
        XCTAssertEqual(try text("brief-site-1-101-401"), "# Essay 1\n\nWrite 500 words.\n")
        let readme = try XCTUnwrap(database.fetchItem(id: "readme-site-1-101-10"))
        XCTAssertEqual(readme.parentID, section)
        XCTAssertEqual(readme.filename, "README.md")
        XCTAssertEqual(readme.fileSize, Int64(try XCTUnwrap(text(readme.id)).utf8.count))
        XCTAssertEqual(try text(readme.id), "Bring a laptop & charger\n")
        XCTAssertNotNil(try database.fetchItem(id: "file-site-1-101-301-notes.pdf"), "Existing files keep their identity")

        // Moodle refuses the assignment request: keep what the folder had.
        try await engine(snapshot: withLabel).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(Set(try database.fetchItems(parentID: folder, siteID: site.id).map(\.filename)), ["rubric.pdf", "README.md"])
        XCTAssertEqual(try text("brief-site-1-101-401"), "# Essay 1\n\nWrite 500 words.\n")
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)

        // The label is removed: so are its README and stored text.
        let withoutLabel = #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"type":"file","filename":"notes.pdf","filesize":20}]},{"id":401,"name":"Essay 1","modname":"assign"}]}]"#
        try await engine(snapshot: withoutLabel, assignments: assignments).syncCourse(site: site, token: token, course: course)
        XCTAssertNil(try database.fetchItem(id: "readme-site-1-101-10"))
        XCTAssertNil(try text("readme-site-1-101-10"))
    }

    func testDatesComeFromMoodleAndAnUnchangedSyncLeavesThemAlone() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        func snapshot(folderFileModified: Int) -> String {
            let file = #"{"id":301,"modname":"resource","contents":[{"type":"file","filename":"notes.pdf","filesize":20,"timemodified":100}]}"#
            let folder = #"{"id":302,"name":"Labs","modname":"folder","contents":[{"type":"file","filename":"a.pdf","filesize":5,"timemodified":200},{"type":"file","filename":"b.pdf","filesize":5,"timemodified":\#(folderFileModified)}]}"#
            let page = #"{"id":303,"name":"Welcome","modname":"page","contents":[{"type":"file","filename":"index.html","filepath":"/","filesize":50,"timecreated":10,"timemodified":400,"fileurl":"https://moodle.example.edu/webservice/pluginfile.php/1/mod_page/content/1/index.html"},{"type":"file","filename":"photo.png","filepath":"/","filesize":9,"timemodified":900}]}"#
            return #"[{"id":10,"section":1,"modules":["# + [file, folder, page].joined(separator: ",") + #"]},{"id":11,"section":2,"modules":[{"id":501,"modname":"label","description":"<p>Bring a laptop</p>"}]}]"#
        }
        func date(_ id: String) throws -> TimeInterval? {
            try database.fetchItem(id: id)?.modificationDate?.timeIntervalSince1970
        }
        let courseID = "course-site-1-101", section = "section-site-1-101-10", folder = "folder-site-1-101-302"
        let page = "page-site-1-101-303", labels = "section-site-1-101-11", readme = "readme-site-1-101-11"

        try await engine(snapshot: snapshot(folderFileModified: 300)).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try date(folder), 300, "A folder shows the newest file inside it")
        XCTAssertEqual(try date(section), 400)
        XCTAssertEqual(try date(courseID), try XCTUnwrap(date(labels)), "The section README is the newest item")
        let welcome = try XCTUnwrap(database.fetchItem(id: page))
        XCTAssertEqual(welcome.modificationDate?.timeIntervalSince1970, 400, "Its images don't date the page")
        XCTAssertEqual(welcome.creationDate?.timeIntervalSince1970, 10)
        XCTAssertEqual(welcome.fileSize, 50)
        XCTAssertNotNil(welcome.remoteURL)
        let readmeDate = try XCTUnwrap(date(readme))
        XCTAssertEqual(readmeDate, readmeDate.rounded(.down), "A first-seen date reads back unchanged")
        let items = try database.fetchItems(courseID: course.id, siteID: site.id)
        XCTAssertTrue(items.allSatisfy { $0.modificationDate != nil })

        let anchor = try database.currentChangeCounter()
        try await engine(snapshot: snapshot(folderFileModified: 300)).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try database.currentChangeCounter(), anchor, "An unchanged sync rewrites nothing")
        XCTAssertEqual(try database.fetchItems(courseID: course.id, siteID: site.id), items)

        try await engine(snapshot: snapshot(folderFileModified: 700)).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try date(folder), 700)
        XCTAssertEqual(try date(section), 700)
        XCTAssertEqual(try date(readme), readmeDate, "Unchanged text keeps its date")
        XCTAssertEqual(try date(courseID), max(700, readmeDate))
    }

    func testAuthorsComeFromMoodleAndAChangeKeepsTheDownload() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        func snapshot(author: String) -> String {
            #"[{"id":10,"section":1,"modules":[{"id":301,"modname":"resource","contents":[{"type":"file","filename":"notes.pdf","filesize":20,"timemodified":100,"author":"\#(author)"}]}]}]"#
        }
        let id = "file-site-1-101-301-notes.pdf"
        try await engine(snapshot: snapshot(author: " Prof. Smith ")).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try database.fetchItem(id: id)?.author, "Prof. Smith")

        var downloaded = try XCTUnwrap(database.fetchItem(id: id))
        downloaded.syncState = .materialized
        try database.saveItems([downloaded])
        try await engine(snapshot: snapshot(author: "Dr. Jones")).syncCourse(site: site, token: token, course: course)
        let updated = try XCTUnwrap(database.fetchItem(id: id))
        XCTAssertEqual(updated.author, "Dr. Jones")
        XCTAssertEqual(updated.syncState, .materialized)

        try await engine(snapshot: snapshot(author: "")).syncCourse(site: site, token: token, course: course)
        XCTAssertNil(try database.fetchItem(id: id)?.author)
    }

    func testPagesFromEarlierBuildsGainAVersionWithoutBecomingNew() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        try database.saveItems([
            LocalItem(id: "course-site-1-101", siteID: site.id, courseID: 101, remoteID: 101, filename: "C101",
                      isDirectory: true, modificationDate: Date(), syncState: .materialized),
            LocalItem(id: "section-site-1-101-10", parentID: "course-site-1-101", siteID: site.id, courseID: 101,
                      remoteID: 10, filename: "Section 1", isDirectory: true, modificationDate: Date(), syncState: .materialized),
            LocalItem(id: "page-site-1-101-303", parentID: "section-site-1-101-10", siteID: site.id, courseID: 101,
                      remoteID: 303, filename: "Welcome.html", contentType: "text/html", modificationDate: Date())
        ])
        let snapshot = #"[{"id":10,"section":1,"modules":[{"id":303,"name":"Welcome","modname":"page","contents":[{"type":"file","filename":"index.html","filepath":"/","filesize":50,"timemodified":400,"fileurl":"https://moodle.example.edu/webservice/pluginfile.php/1/mod_page/content/1/index.html"}]}]}]"#
        try await engine(snapshot: snapshot).syncCourse(site: site, token: token, course: course)
        let page = try XCTUnwrap(database.fetchItem(id: "page-site-1-101-303"))
        XCTAssertEqual(page.fileSize, 50)
        XCTAssertEqual(page.modificationDate?.timeIntervalSince1970, 400)
        XCTAssertEqual(try database.fetchNewItems(courseID: course.id, siteID: site.id), [])
    }

    func testLaterSyncsBringInAddedAndChangedFiles() async throws {
        let site = MoodleSite(id: "site-1", displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 101, shortName: "C101", fullName: "Course 101", siteID: site.id)
        let token = AuthToken(token: "token")
        func snapshot(_ files: [(module: Int, name: String, modified: Int)]) -> String {
            let modules = files.map { #"{"id":\#($0.module),"modname":"resource","contents":[{"type":"file","filename":"\#($0.name)","filesize":20,"timemodified":\#($0.modified)}]}"# }
            return #"[{"id":10,"section":1,"modules":["# + modules.joined(separator: ",") + "]}]"
        }
        func newNames() throws -> Set<String> {
            Set(try database.fetchNewItems(courseID: course.id, siteID: site.id).map(\.filename))
        }

        try await engine(snapshot: snapshot([(301, "syllabus.pdf", 1)])).syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try newNames(), [], "The first sync of a course is its baseline")

        try await engine(snapshot: snapshot([(301, "syllabus.pdf", 1), (302, "week1.pdf", 1)]))
            .syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try newNames(), ["week1.pdf"])

        let week1 = try XCTUnwrap(database.fetchItems(courseID: course.id, siteID: site.id).first { $0.filename == "week1.pdf" })
        try database.markItemOpened(id: try XCTUnwrap(week1.parentID), at: Date())
        XCTAssertEqual(try newNames(), [])

        try await engine(snapshot: snapshot([(301, "syllabus.pdf", 2), (302, "week1.pdf", 1)]))
            .syncCourse(site: site, token: token, course: course)
        XCTAssertEqual(try newNames(), ["syllabus.pdf"], "Replaced content is new again; unchanged files stay seen")
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
              var snapshot = request.value(forHTTPHeaderField: "X-Test-Course-Snapshot"),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if requestBody().contains("wsfunction=mod_assign_get_assignments") {
            snapshot = request.value(forHTTPHeaderField: "X-Test-Assignments")
                ?? #"{"errorcode":"nopermissions","message":"Sorry, but you do not currently have permissions to do that."}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(snapshot.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
