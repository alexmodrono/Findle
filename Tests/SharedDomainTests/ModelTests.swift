// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain

final class ModelTests: XCTestCase {

    func testDiscoveryPreservesCanonicalSiteIdentityAndRefreshesCapabilities() {
        let existing = MoodleSite(id: "existing", displayName: "Old", baseURL: URL(string: "https://MOODLE.example.edu:443/campus/")!)
        let discovered = MoodleSite(displayName: "New", baseURL: URL(string: "https://moodle.example.edu/campus")!,
                                    capabilities: SiteCapabilities(loginType: .embedded))
        let reconciled = discovered.preservingIdentity(from: [existing])
        XCTAssertEqual(reconciled.id, existing.id)
        XCTAssertEqual(reconciled.displayName, "New")
        XCTAssertEqual(reconciled.capabilities.loginType, .embedded)
        XCTAssertEqual(reconciled.baseURL, discovered.baseURL)
    }

    func testDiscoveryDoesNotMergeDistinctServers() {
        let existing = MoodleSite(id: "existing", displayName: "Site", baseURL: URL(string: "https://example.edu/campus")!)
        for address in ["https://elsewhere.edu/campus", "http://example.edu/campus", "https://example.edu/Campus",
                        "https://example.edu/other", "https://example.edu:8443/campus", "https://example.edu/campus?tenant=2"] {
            let discovered = MoodleSite(displayName: "Other", baseURL: URL(string: address)!)
            XCTAssertEqual(discovered.preservingIdentity(from: [existing]).id, discovered.id, address)
        }
        let root = MoodleSite(id: "root", displayName: "Root", baseURL: URL(string: "https://example.edu/")!)
        let discovered = MoodleSite(displayName: "Root", baseURL: URL(string: "https://example.edu")!)
        XCTAssertEqual(discovered.preservingIdentity(from: [root]).id, "root")
    }

    func testReauthenticationPreservesAccountHistory() throws {
        let old = Account(id: "account", siteID: "site", userID: 42, state: .expired,
                          lastSyncDate: Date(timeIntervalSince1970: 200), createdAt: Date(timeIntervalSince1970: 100))
        let refreshed = try old.reauthenticated(siteID: "site", userID: 42)
        XCTAssertEqual(refreshed.id, old.id)
        XCTAssertEqual(refreshed.lastSyncDate, old.lastSyncDate)
        XCTAssertEqual(refreshed.createdAt, old.createdAt)
        XCTAssertEqual(refreshed.state, .authenticated(userID: 42))
        XCTAssertThrowsError(try old.reauthenticated(siteID: "another-site", userID: 42))
        XCTAssertThrowsError(try old.reauthenticated(siteID: "site", userID: 43))
    }

    func testMoodleSiteURLs() {
        let site = MoodleSite(
            displayName: "Test",
            baseURL: URL(string: "https://moodle.example.edu")!
        )

        XCTAssertEqual(site.webServiceURL.absoluteString, "https://moodle.example.edu/webservice/rest/server.php")
        XCTAssertEqual(site.tokenURL.absoluteString, "https://moodle.example.edu/login/token.php")
    }

    func testSiteCapabilitiesCompatibility() {
        let compatible = SiteCapabilities(
            supportsWebServices: true,
            supportsFileDownload: true
        )
        XCTAssertTrue(compatible.isCompatible)

        let incompatible = SiteCapabilities(
            supportsWebServices: false,
            supportsFileDownload: true
        )
        XCTAssertFalse(incompatible.isCompatible)
    }

    func testCourseSanitizedFolderName() {
        let course = MoodleCourse(
            id: 1,
            shortName: "CS101",
            fullName: "Introduction to Computer Science: Fall 2024",
            siteID: "test"
        )
        let name = course.sanitizedFolderName
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("/"))
    }

    func testResourceTypeDownloadable() {
        XCTAssertTrue(ResourceType.file.isDownloadable)
        XCTAssertTrue(ResourceType.folder.isDownloadable)
        XCTAssertTrue(ResourceType.url.isDownloadable)
        XCTAssertFalse(ResourceType.quiz.isDownloadable)
        XCTAssertFalse(ResourceType.forum.isDownloadable)
    }

    func testResourceTypeContainer() {
        XCTAssertTrue(ResourceType.folder.isContainer)
        XCTAssertFalse(ResourceType.file.isContainer)
    }

    func testAccountState() {
        let connected = AccountState.authenticated(userID: 42)
        XCTAssertTrue(connected.isConnected)
        XCTAssertFalse(connected.needsReauth)

        let expired = AccountState.expired
        XCTAssertFalse(expired.isConnected)
        XCTAssertTrue(expired.needsReauth)

        let disconnected = AccountState.disconnected
        XCTAssertFalse(disconnected.isConnected)
        XCTAssertFalse(disconnected.needsReauth)
    }

    func testItemSyncState() {
        let state = ItemSyncState.placeholder
        XCTAssertEqual(state.rawValue, "placeholder")
        XCTAssertEqual(ItemSyncState(rawValue: "materialized"), .materialized)
    }

    func testLocalItemDefaults() {
        let item = LocalItem(
            siteID: "test",
            courseID: 1,
            remoteID: 100,
            filename: "test.pdf"
        )
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.fileSize, 0)
        XCTAssertEqual(item.syncState, .placeholder)
        XCTAssertFalse(item.isPinned)
    }

    func testSyncCursorInit() {
        let cursor = SyncCursor(courseID: 101, siteID: "test")
        XCTAssertEqual(cursor.courseID, 101)
        XCTAssertEqual(cursor.siteID, "test")
        XCTAssertEqual(cursor.itemCount, 0)
    }

    func testRequiresReauthentication() {
        XCTAssertTrue(FindleError.tokenExpired.requiresReauthentication)
        XCTAssertTrue(FindleError.tokenRefreshFailed(underlying: "x").requiresReauthentication)
        XCTAssertTrue(FindleError.authenticationRequired.requiresReauthentication)

        XCTAssertFalse(FindleError.networkUnavailable.requiresReauthentication)
        XCTAssertFalse(FindleError.timeout.requiresReauthentication)
        XCTAssertFalse(FindleError.invalidCredentials.requiresReauthentication)
    }
}
