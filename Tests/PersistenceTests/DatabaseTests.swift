import XCTest
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
}
