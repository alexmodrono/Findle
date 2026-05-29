// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain
@testable import FoodleNetworking
@testable import FoodlePersistence
@testable import FoodleSyncEngine

final class SyncEngineReauthTests: XCTestCase {
    var database: Database!
    var tempPath: String!

    private let site = MoodleSite(
        id: "site-1",
        displayName: "Example",
        baseURL: URL(string: "https://moodle.example.edu")!,
        capabilities: SiteCapabilities(
            supportsWebServices: true,
            supportsMobileAPI: true,
            supportsFileDownload: true
        )
    )
    private let token = AuthToken(token: "token")

    override func setUp() async throws {
        tempPath = NSTemporaryDirectory() + "foodle_reauth_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testSyncAllCoursesRethrowsAuthenticationFailure() async throws {
        let provider = ThrowingLMSProvider(error: .tokenExpired)
        let engine = SyncEngine(provider: provider, database: database)
        let courses = [MoodleCourse(id: 1, shortName: "C1", fullName: "Course 1", siteID: site.id)]

        do {
            try await engine.syncAllCourses(site: site, token: token, courses: courses)
            XCTFail("Expected syncAllCourses to rethrow the authentication failure")
        } catch let error as FoodleError {
            XCTAssertTrue(error.requiresReauthentication)
        }
    }

    func testSyncAllCoursesContinuesPastNonAuthFailure() async throws {
        // A non-auth failure on one course must not abort the whole pass.
        let provider = ThrowingLMSProvider(error: .networkUnavailable)
        let engine = SyncEngine(provider: provider, database: database)
        let courses = [
            MoodleCourse(id: 1, shortName: "C1", fullName: "Course 1", siteID: site.id),
            MoodleCourse(id: 2, shortName: "C2", fullName: "Course 2", siteID: site.id),
        ]

        // Should complete without throwing even though every course errors.
        try await engine.syncAllCourses(site: site, token: token, courses: courses)
    }
}

private struct ThrowingLMSProvider: LMSProvider {
    let error: FoodleError

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
        throw error
    }

    func downloadFile(url: URL, token: AuthToken, destination: URL) async throws {}

    func authenticatedFileRequest(fileURL: URL, token: AuthToken) -> URLRequest {
        URLRequest(url: fileURL)
    }
}
