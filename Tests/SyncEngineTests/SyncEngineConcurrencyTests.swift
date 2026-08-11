// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain
@testable import FindleNetworking
@testable import FindlePersistence
@testable import FindleSyncEngine

/// Covers the bounded-concurrency batch sync and its per-course completion
/// callback — the mechanism that lets Finder show a course's files as soon as
/// that course lands instead of waiting for the whole run.
final class SyncEngineConcurrencyTests: XCTestCase {
    private var database: Database!
    private var tempPath: String!

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
        tempPath = NSTemporaryDirectory() + "findle_concurrency_test_\(UUID().uuidString).db"
        database = try Database(path: tempPath)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func makeCourses(_ count: Int) -> [MoodleCourse] {
        (1...count).map {
            MoodleCourse(id: $0, shortName: "C\($0)", fullName: "Course \($0)", siteID: site.id)
        }
    }

    func testEveryCourseReportsCompletionExactlyOnce() async throws {
        let courses = makeCourses(8)
        let provider = RecordingLMSProvider()
        let engine = SyncEngine(provider: provider, database: database)
        let synced = SyncedCourseRecorder()

        try await engine.syncAllCourses(
            site: site,
            token: token,
            courses: courses,
            onCourseSynced: { synced.record($0) }
        )

        XCTAssertEqual(synced.ids.sorted(), courses.map(\.id))
        XCTAssertEqual(synced.ids.count, Set(synced.ids).count, "A course reported completion more than once")
    }

    func testCoursesFetchConcurrentlyUpToTheLimit() async throws {
        let courses = makeCourses(8)
        let provider = RecordingLMSProvider(fetchDelay: .milliseconds(50))
        let engine = SyncEngine(provider: provider, database: database)

        try await engine.syncAllCourses(
            site: site,
            token: token,
            courses: courses,
            maxConcurrentCourses: 4
        )

        XCTAssertEqual(provider.completedFetchCount, courses.count)
        // The whole point of the change: more than one course in flight at once,
        // but never more than the cap.
        XCTAssertGreaterThan(provider.peakConcurrency, 1, "Course fetches never overlapped")
        XCTAssertLessThanOrEqual(provider.peakConcurrency, 4, "Exceeded the concurrency limit")
    }

    func testConcurrencyLimitOfOneKeepsFetchesSerial() async throws {
        let courses = makeCourses(4)
        let provider = RecordingLMSProvider(fetchDelay: .milliseconds(20))
        let engine = SyncEngine(provider: provider, database: database)

        try await engine.syncAllCourses(
            site: site,
            token: token,
            courses: courses,
            maxConcurrentCourses: 1
        )

        XCTAssertEqual(provider.peakConcurrency, 1)
        XCTAssertEqual(provider.completedFetchCount, courses.count)
    }

    func testFailedCourseDoesNotReportCompletion() async throws {
        let courses = makeCourses(4)
        // Course 3 fails with a non-auth error; the rest must still complete.
        let provider = RecordingLMSProvider(failingCourseIDs: [3], failure: .networkUnavailable)
        let engine = SyncEngine(provider: provider, database: database)
        let synced = SyncedCourseRecorder()

        try await engine.syncAllCourses(
            site: site,
            token: token,
            courses: courses,
            onCourseSynced: { synced.record($0) }
        )

        XCTAssertEqual(synced.ids.sorted(), [1, 2, 4])
    }
}

private final class SyncedCourseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var ids: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(id)
    }
}

/// Tracks how many `fetchCourseContents` calls are in flight simultaneously so
/// tests can assert on the concurrency window.
private final class RecordingLMSProvider: LMSProvider, @unchecked Sendable {
    private let fetchDelay: Duration?
    private let failingCourseIDs: Set<Int>
    private let failure: FindleError

    private let lock = NSLock()
    private var inFlight = 0
    private var _peakConcurrency = 0
    private var _completedFetchCount = 0

    init(
        fetchDelay: Duration? = nil,
        failingCourseIDs: Set<Int> = [],
        failure: FindleError = .networkUnavailable
    ) {
        self.fetchDelay = fetchDelay
        self.failingCourseIDs = failingCourseIDs
        self.failure = failure
    }

    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return _peakConcurrency
    }

    var completedFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _completedFetchCount
    }

    // NSLock's lock/unlock are unavailable directly inside an async function, so
    // the bookkeeping lives in these synchronous helpers.
    private func beginFetch() {
        lock.lock()
        defer { lock.unlock() }
        inFlight += 1
        _peakConcurrency = max(_peakConcurrency, inFlight)
    }

    private func endFetch() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }

    private func recordCompletedFetch() {
        lock.lock()
        defer { lock.unlock() }
        _completedFetchCount += 1
    }

    func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection] {
        beginFetch()
        defer { endFetch() }

        if let fetchDelay {
            try await Task.sleep(for: fetchDelay)
        }

        if failingCourseIDs.contains(courseID) {
            throw failure
        }

        recordCompletedFetch()

        return [
            MoodleSection(
                id: 1,
                courseID: courseID,
                name: "Section 1",
                sectionNumber: 0,
                visible: true,
                modules: []
            )
        ]
    }

    // MARK: - Unused by these tests

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

    func downloadFile(url: URL, token: AuthToken, destination: URL) async throws {}

    func authenticatedFileRequest(fileURL: URL, token: AuthToken) -> URLRequest {
        URLRequest(url: fileURL)
    }
}
