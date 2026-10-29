import XCTest
import Synchronization
import SharedDomain
import FindleNetworking
import FindlePersistence
@testable import FindleSyncEngine

final class SyncRunReportTests: XCTestCase {
    private let site = MoodleSite(id: "report-site", displayName: "Test", baseURL: URL(string: "https://example.test")!)
    private let token = AuthToken(token: "test-token")
    private var database: Database!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try Database(path: directory.appendingPathComponent("test.db").path)
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func courses(_ count: Int = 3) -> [MoodleCourse] {
        (1...count).map { MoodleCourse(id: $0, shortName: "C\($0)", fullName: "Course \($0)", siteID: site.id) }
    }

    func testOneFailurePreservesItsCursorAndRecoveryBecomesFullSuccess() async throws {
        let provider = ReportProvider()
        let engine = SyncEngine(provider: provider, database: database)
        let initial = await engine.syncAllCourses(site: site, token: token, courses: courses())
        XCTAssertTrue(initial.allSucceeded)
        let cursor = try database.fetchSyncCursor(courseID: 2, siteID: site.id)
        let items = try database.fetchItems(courseID: 2, siteID: site.id)
        await provider.setFailure(.networkUnavailable, courseID: 2)
        let partial = await engine.syncAllCourses(site: site, token: token, courses: courses())
        XCTAssertEqual(partial.succeededCount, 2)
        XCTAssertEqual(partial.failedCount, 1)
        XCTAssertNil(partial.successfulCompletionDate)
        XCTAssertEqual(partial.courses[1].lastSuccessfulSync, cursor?.lastSyncDate)
        XCTAssertEqual(try database.fetchSyncCursor(courseID: 2, siteID: site.id), cursor)
        XCTAssertEqual(try database.fetchItems(courseID: 2, siteID: site.id), items, "Cached browsing must survive an outage")
        await provider.setFailure(nil, courseID: 2)
        let recovery = await engine.syncAllCourses(site: site, token: token, courses: courses())
        XCTAssertTrue(recovery.allSucceeded)
        XCTAssertEqual(recovery.succeededCount, 3)
        XCTAssertNotNil(recovery.successfulCompletionDate)
        let attempts = await provider.authenticationAttempts
        XCTAssertEqual(attempts, 0)
        let events = try XCTUnwrap(DiagnosticJournal(databasePath: database.filePath)).read()
        let partialEvents = events.filter { $0.attemptID == partial.id }
        XCTAssertEqual(partialEvents.map(\.outcome), [.started, .partial])
        XCTAssertEqual(partialEvents.last?.failure?.kind, "networkUnavailable")
    }

    func testOfflineStartupAndAllFailuresAreNotSuccess() async throws {
        let provider = ReportProvider()
        let engine = SyncEngine(provider: provider, database: database)
        for course in courses() { await provider.setFailure(.networkUnavailable, courseID: course.id) }
        let report = await engine.syncAllCourses(site: site, token: token, courses: courses())
        XCTAssertEqual(report.failedCount, 3)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertFalse(report.allSucceeded)
        XCTAssertFalse(report.requiresReauthentication)
        XCTAssertTrue(report.courses.allSatisfy { $0.lastSuccessfulSync == nil })
        XCTAssertTrue(try database.fetchAllItems(siteID: site.id).isEmpty)
    }

    func testTimeoutRateLimitServerErrorAndIncompleteResponsesRemainDistinctAndRecoverable() async throws {
        let provider = ReportProvider()
        let engine = SyncEngine(provider: provider, database: database)
        let selected = courses(1)
        let errors: [FindleError] = [.timeout, .requestFailed(statusCode: 429, detail: "private token"),
                                     .requestFailed(statusCode: 503, detail: "private token"),
                                     .invalidResponse(detail: "private token")]
        for error in errors {
            await provider.setFailure(error, courseID: 1)
            let failed = await engine.syncAllCourses(site: site, token: token, courses: selected)
            XCTAssertFalse(failed.allSucceeded)
            XCTAssertFalse(failed.requiresReauthentication)
            XCTAssertEqual(failed.courses.first?.failure, DiagnosticFailure(error))
            if case .invalidResponse = error { XCTAssertEqual(failed.incompleteCount, 1) }
            else { XCTAssertEqual(failed.failedCount, 1) }
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failed), as: UTF8.self).contains("private token"))
            await provider.setFailure(nil, courseID: 1)
            let recovered = await engine.syncAllCourses(site: site, token: token, courses: selected)
            XCTAssertTrue(recovered.allSucceeded)
        }
        let attempts = await provider.authenticationAttempts
        XCTAssertEqual(attempts, 0)
    }

    func testCancellationAccountsForStartedAndUnstartedWorkWithoutPublishing() async throws {
        let gate = FetchGate()
        let provider = ReportProvider(gate: gate)
        let engine = SyncEngine(provider: provider, database: database)
        let site = site, token = token, selected = courses()
        let run = Task { await engine.syncAllCourses(site: site, token: token, courses: selected, maxConcurrentCourses: 1) }
        await gate.waitUntilStarted()
        run.cancel()
        await gate.release()
        let report = await run.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.cancelledCount, 1)
        XCTAssertEqual(report.skippedCount, 2)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertTrue(try database.fetchAllItems(siteID: site.id).isEmpty)
        XCTAssertNil(try database.fetchSyncCursor(courseID: 1, siteID: site.id))
        let fetched = await provider.fetchedCourseIDs
        XCTAssertEqual(fetched, [1])
        let recovered = await engine.syncAllCourses(site: site, token: token, courses: selected)
        XCTAssertTrue(recovered.allSucceeded)
    }

    func testUnsubscribeDuringFetchIsSkippedWithoutPublishing() async throws {
        let gate = FetchGate()
        let provider = ReportProvider(gate: gate)
        let engine = SyncEngine(provider: provider, database: database)
        let site = site, token = token, selected = courses(1)
        try database.saveCourses(selected)
        let run = Task { await engine.syncAllCourses(site: site, token: token, courses: selected) }
        await gate.waitUntilStarted()
        try database.updateCourseSubscription(courseID: 1, siteID: site.id, state: .unsubscribed)
        await gate.release()
        let report = await run.value
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertFalse(report.allSucceeded)
        XCTAssertNil(try database.fetchSyncCursor(courseID: 1, siteID: site.id))
        XCTAssertTrue(try database.fetchAllItems(siteID: site.id).isEmpty)
    }

    func testEmptySelectionDoesNoNetworkOrDownloadWork() async throws {
        let provider = ReportProvider()
        let engine = SyncEngine(provider: provider, database: database)
        let report = await engine.syncAllCourses(site: site, token: token, courses: [])
        XCTAssertTrue(report.isNoOp)
        XCTAssertFalse(report.allSucceeded)
        XCTAssertNil(report.successfulCompletionDate)
        let fetched = await provider.fetchedCourseIDs
        let downloads = await provider.downloadAttempts
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertEqual(downloads, 0)
        XCTAssertTrue(try XCTUnwrap(DiagnosticJournal(databasePath: database.filePath)).read().isEmpty)
    }

    func testRealHTTPAndTransportFailuresKeepCachedDataAndReportOutcome() async throws {
        let good = ReportHTTPFixture()
        let initial = await SyncEngine(provider: good.client, database: database)
            .syncAllCourses(site: site, token: token, courses: courses(1))
        XCTAssertTrue(initial.allSucceeded)
        let cursor = try database.fetchSyncCursor(courseID: 1, siteID: site.id)
        let fixtures: [(ReportHTTPFixture, SyncCourseOutcome.Outcome, Int)] = [
            (ReportHTTPFixture(body: "<html>Sign in</html>"), .incomplete, 1),
            (ReportHTTPFixture(status: 429), .failed, 1),
            (ReportHTTPFixture(status: 503), .failed, 1),
            (ReportHTTPFixture(transport: URLError.notConnectedToInternet.rawValue), .failed, 1),
            (ReportHTTPFixture(transport: URLError.timedOut.rawValue), .failed, 3)
        ]
        for (fixture, expectedOutcome, attempts) in fixtures {
            let engine = SyncEngine(provider: fixture.client, database: database)
            let report = await engine.syncAllCourses(site: site, token: token, courses: courses(1))
            XCTAssertEqual(report.courses.first?.outcome, expectedOutcome)
            XCTAssertFalse(report.allSucceeded)
            XCTAssertFalse(report.requiresReauthentication, "An outage/HTML page is not proof the token expired")
            XCTAssertEqual(try database.fetchSyncCursor(courseID: 1, siteID: site.id), cursor)
            XCTAssertFalse(try database.fetchItems(courseID: 1, siteID: site.id).isEmpty)
            XCTAssertEqual(fixture.attempts, attempts)
        }
    }

    func testTransientReadRetriesRecoverButCredentialSubmissionIsNeverReplayed() async throws {
        let recovering = ReportHTTPFixture(transport: URLError.networkConnectionLost.rawValue, failures: 1)
        let report = await SyncEngine(provider: recovering.client, database: database)
            .syncAllCourses(site: site, token: token, courses: courses(1))
        XCTAssertTrue(report.allSucceeded)
        XCTAssertEqual(recovering.attempts, 2)
        let signIn = ReportHTTPFixture(transport: URLError.networkConnectionLost.rawValue)
        do {
            _ = try await signIn.client.authenticate(site: site, username: "test-user", password: "test-password")
            XCTFail("Lost sign-in response should fail without another password submission")
        } catch { XCTAssertEqual(signIn.attempts, 1) }
    }

    func testPinnedDownloadFailureIsIncompleteAndNextRunRetriesIt() async throws {
        let provider = ReportProvider()
        let engine = SyncEngine(provider: provider, database: database)
        let selected = courses(1)
        await engine.syncAllCourses(site: site, token: token, courses: selected)
        let item = try XCTUnwrap(database.fetchItems(courseID: 1, siteID: site.id).first { !$0.isDirectory })
        try database.updateItemPinned(id: item.id, isPinned: true)
        await provider.setDownloadFailure(.networkUnavailable)
        let partial = await engine.syncAllCourses(site: site, token: token, courses: selected)
        XCTAssertEqual(partial.incompleteCount, 1)
        XCTAssertFalse(partial.allSucceeded)
        XCTAssertEqual(try database.fetchItem(id: item.id)?.syncState, .error)
        do {
            try await engine.syncCourse(site: site, token: token, course: selected[0])
            XCTFail("Single-course callers must also observe failed pinned downloads")
        } catch let error as FindleError {
            guard case .downloadFailed = error else { return XCTFail("Expected safe download failure") }
        }
        await provider.setDownloadFailure(nil)
        let recovery = await engine.syncAllCourses(site: site, token: token, courses: selected)
        XCTAssertTrue(recovery.allSucceeded)
        let materialized = try XCTUnwrap(database.fetchItem(id: item.id))
        XCTAssertEqual(materialized.syncState, .materialized)
        let localPath = try XCTUnwrap(materialized.localPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localPath)), Data("complete".utf8))
        try FileManager.default.removeItem(atPath: localPath)
        let downloads = await provider.downloadAttempts
        XCTAssertEqual(downloads, 3)
    }
}

private actor FetchGate {
    private var started = false
    private var released = false
    private var ready: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        started = true
        ready?.resume(); ready = nil
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { ready = $0 } }
    }
    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

private actor ReportProvider: LMSProvider {
    private var failures: [Int: FindleError] = [:]
    private var downloadFailure: FindleError?
    private let gate: FetchGate?
    private(set) var fetchedCourseIDs: [Int] = []
    private(set) var authenticationAttempts = 0
    private(set) var downloadAttempts = 0

    init(gate: FetchGate? = nil) { self.gate = gate }
    func setFailure(_ failure: FindleError?, courseID: Int) { failures[courseID] = failure }
    func setDownloadFailure(_ failure: FindleError?) { downloadFailure = failure }

    func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection] {
        fetchedCourseIDs.append(courseID)
        if let gate { await gate.enter() }
        if let failure = failures[courseID] { throw failure }
        return [MoodleSection(id: 1, courseID: courseID, name: "Section", sectionNumber: 0, modules: [
            MoodleModule(id: 1, name: "Notes", modName: "resource", contents: [
                MoodleFileContent(type: "file", fileName: "report-test.txt", fileURL: URL(string: "https://example.test/file")!)
            ])
        ])]
    }
    func downloadFile(url: URL, site: MoodleSite, token: AuthToken, destination: URL) async throws {
        downloadAttempts += 1
        if let downloadFailure {
            try Data("partial".utf8).write(to: destination)
            throw downloadFailure
        }
        try Data("complete".utf8).write(to: destination)
    }
    func validateSite(url: URL) async throws -> MoodleSite { MoodleSite(displayName: "Test", baseURL: url) }
    func authenticate(site: MoodleSite, username: String, password: String) async throws -> AuthToken {
        authenticationAttempts += 1
        throw FindleError.invalidCredentials
    }
    func fetchUserInfo(site: MoodleSite, token: AuthToken) async throws -> MoodleUser {
        MoodleUser(id: 1, username: "test", fullName: "Test", siteID: site.id)
    }
    func fetchCourses(site: MoodleSite, token: AuthToken, userID: Int) async throws -> [MoodleCourse] { [] }
    nonisolated func parseTokenFromSSOCallback(callbackURLString: String, site: MoodleSite, passport: String) throws -> AuthToken {
        throw FindleError.authenticationRequired
    }
    nonisolated func authenticatedFileRequest(fileURL: URL, site: MoodleSite, token: AuthToken) throws -> URLRequest { URLRequest(url: fileURL) }
}


private struct ReportHTTPFixture {
    let id = UUID().uuidString
    let status: Int
    let body: String
    let transport: Int?
    let failures: Int

    init(status: Int = 200, body: String = "[]", transport: Int? = nil, failures: Int = Int.max) {
        self.status = status; self.body = body; self.transport = transport; self.failures = failures
    }
    var client: MoodleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-Test-ID": id, "X-Test-Status": String(status), "X-Test-Body": body,
            "X-Test-Transport": transport.map(String.init) ?? "", "X-Test-Failures": String(failures)
        ]
        return MoodleClient(session: URLSession(configuration: configuration))
    }
    var attempts: Int { ReportURLProtocol.counts.withLock { $0[id] ?? 0 } }
}

private final class ReportURLProtocol: URLProtocol {
    static let counts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let id = request.value(forHTTPHeaderField: "X-Test-ID") else { return }
        let attempt = Self.counts.withLock { counts in
            counts[id, default: 0] += 1
            return counts[id, default: 0]
        }
        if let raw = request.value(forHTTPHeaderField: "X-Test-Transport"), let code = Int(raw),
           attempt <= Int(request.value(forHTTPHeaderField: "X-Test-Failures") ?? "") ?? 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "") ?? 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "X-Test-Body") ?? "[]").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
