import XCTest
import FileProvider
import SharedDomain
import FindlePersistence

/// Talks to the course data service over a real XPC connection, as another
/// Findle extension would once the system hands it the endpoint.
final class CourseDataServiceTests: XCTestCase {
    private let now = Date()

    private func fixture() throws -> ProviderFixture {
        let fixture = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.database.saveCourses([
            MoodleCourse(id: 2, shortName: "PHY", fullName: "Physics", siteID: "a"),
            MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: "a"),
            MoodleCourse(id: 3, shortName: "OLD", fullName: "Archived", siteID: "a", isSyncEnabled: false),
            MoodleCourse(id: 9, shortName: "OTH", fullName: "Other site", siteID: "b")
        ])
        try fixture.database.saveAssignments([
            MoodleAssignment(id: 10, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(7_200), submitted: true),
            MoodleAssignment(id: 11, courseID: 1, name: "Past", dueDate: now.addingTimeInterval(-60)),
            MoodleAssignment(id: 12, courseID: 3, name: "Unsubscribed", dueDate: now.addingTimeInterval(60)),
            MoodleAssignment(id: 13, courseID: 2, name: "No date")
        ], siteID: "a")
        try fixture.database.saveQuizzes([
            MoodleQuiz(id: 20, courseID: 2, name: "Quiz 1", closeDate: now.addingTimeInterval(3_600))
        ], siteID: "a")
        return fixture
    }

    private func proxy(for source: CourseDataServiceSource) throws -> (CourseDataServiceProtocol, NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: try source.makeListenerEndpoint())
        connection.remoteObjectInterface = NSXPCInterface(with: CourseDataServiceProtocol.self)
        connection.resume()
        // Teardown runs after the test is done with the connection.
        nonisolated(unsafe) let finished = connection
        addTeardownBlock { finished.invalidate(); source.invalidate() }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { XCTFail("XPC failed: \($0)") }
        return (try XCTUnwrap(proxy as? CourseDataServiceProtocol), connection)
    }

    private func call(_ method: (@escaping @Sendable (Data?, Error?) -> Void) -> Void) -> (Data?, Error?) {
        let box = ReplyBox()
        method { data, error in box.set(data, error) }
        return box.value
    }

    func testAClientReadsSubscribedCoursesAndUpcomingCoursework() throws {
        let f = try fixture()
        let database = f.database
        let source = CourseDataServiceSource(source: { (database, "a") }, admission: { _ in true })
        let (service, _) = try proxy(for: source)

        let (courseData, courseError) = call(service.fetchCourses)
        XCTAssertNil(courseError)
        let courses = try CourseDataService.decode([CourseDataService.Course].self, from: XCTUnwrap(courseData))
        XCTAssertEqual(courses.map(\.fullName), ["Algebra", "Physics"], "Subscribed courses of this site, by name")

        let (workData, workError) = call(service.fetchUpcomingCoursework)
        XCTAssertNil(workError)
        let work = try CourseDataService.decode([CourseDataService.Coursework].self, from: XCTUnwrap(workData))
        XCTAssertEqual(work.map(\.name), ["Quiz 1", "Essay"], "Soonest first; past, undated and unsubscribed left out")
        XCTAssertEqual(work.map(\.kind), [.quiz, .assignment])
        XCTAssertEqual(work.last?.submitted, true)
        XCTAssertEqual(work.first?.due.timeIntervalSince1970 ?? 0, now.addingTimeInterval(3_600).timeIntervalSince1970, accuracy: 1)
    }

    private func sheetsProxy(for source: CourseDataServiceSource) throws -> CourseDataSheetsProtocol {
        let connection = NSXPCConnection(listenerEndpoint: try source.makeListenerEndpoint())
        connection.remoteObjectInterface = NSXPCInterface(with: CourseDataSheetsProtocol.self)
        connection.resume()
        nonisolated(unsafe) let finished = connection
        addTeardownBlock { finished.invalidate(); source.invalidate() }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { XCTFail("XPC failed: \($0)") }
        return try XCTUnwrap(proxy as? CourseDataSheetsProtocol)
    }

    func testFindersSheetsReadCourseInfoAndAssignmentDetails() throws {
        let f = try fixture()
        let database = f.database
        try database.saveCourseTeachers([1: ["Dr. Ruiz", "Prof. Lee"]], siteID: "a")
        try database.saveItems([
            LocalItem(id: "course-a-1", siteID: "a", courseID: 1, remoteID: 1, filename: "Algebra", isDirectory: true),
            LocalItem(id: "assign-a-1-40", parentID: "course-a-1", siteID: "a", courseID: 1, remoteID: 40, filename: "Essay",
                      isDirectory: true),
            LocalItem(id: "file-a-1-5-x.pdf", parentID: "course-a-1", siteID: "a", courseID: 1, remoteID: 5, filename: "x.pdf",
                      fileSize: 1_000, syncState: .materialized),
            LocalItem(id: "file-a-1-5-y.pdf", parentID: "course-a-1", siteID: "a", courseID: 1, remoteID: 5, filename: "y.pdf",
                      fileSize: 5_000),
        ])
        try database.saveAssignments([MoodleAssignment(id: 10, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(7_200),
                                                       moduleID: 40, submitted: true, graded: true, grade: "9")], siteID: "a")
        nonisolated(unsafe) var kept: [(Int, Bool)] = []
        let source = CourseDataServiceSource(source: { (database, "a") }, keep: { kept.append(($0, $1)) },
                                             admission: { _ in true })
        let service = try sheetsProxy(for: source)

        let (infoData, infoError) = call { service.fetchCourseInfo(courseID: 1, reply: $0) }
        XCTAssertNil(infoError)
        let info = try CourseDataService.decode(CourseDataService.CourseInfo.self, from: XCTUnwrap(infoData))
        XCTAssertEqual(info.teachers, ["Dr. Ruiz", "Prof. Lee"])
        XCTAssertEqual(info.storageBytes, 1_000, "Only what is on this Mac counts")
        XCTAssertFalse(info.keptOffline)

        let (detailData, _) = call { service.fetchAssignmentDetails(itemID: "assign-a-1-40", reply: $0) }
        let details = try CourseDataService.decode(CourseDataService.AssignmentDetails.self, from: XCTUnwrap(detailData))
        XCTAssertEqual(details.courseName, "Algebra")
        XCTAssertEqual(details.status, "Graded: 9")

        let (_, missing) = call { service.fetchAssignmentDetails(itemID: "file-a-1-5-x.pdf", reply: $0) }
        XCTAssertNotNil(missing, "Only assignment folders have details")

        let box = ReplyBox()
        service.setCourseKeptOffline(courseID: 1, kept: true) { box.set(nil, $0) }
        XCTAssertNil(box.value.1)
        XCTAssertEqual(kept.map(\.0), [1])
        XCTAssertEqual(kept.map(\.1), [true])
    }

    func testTheSheetsAddOnlyTheKeptStateAsAWrite() {
        let methods = protocolMethodNames(CourseDataSheetsProtocol.self)
        XCTAssertEqual(methods, ["fetchAssignmentDetailsWithItemID:reply:", "fetchCourseInfoWithCourseID:reply:",
                                 "setCourseKeptOfflineWithCourseID:kept:reply:"],
                       "Keep Course Offline from Course Info is the one write, as Finder's action")
    }

    func testServiceIsReadOnly() throws {
        let f = try fixture()
        let database = f.database
        let anchor = try database.currentChangeCounter()
        let source = CourseDataServiceSource(source: { (database, "a") }, admission: { _ in true })
        let (service, _) = try proxy(for: source)
        _ = call(service.fetchCourses)
        _ = call(service.fetchUpcomingCoursework)
        XCTAssertEqual(try database.currentChangeCounter(), anchor)
        let methods = protocolMethodNames(CourseDataServiceProtocol.self)
        XCTAssertEqual(methods, ["fetchCoursesWithReply:", "fetchUpcomingCourseworkWithReply:"],
                       "Adding a method needs a review: this service must stay read-only unless a task adds a specific write")
    }

    func testUnavailableDatabaseRepliesWithAnErrorInsteadOfData() throws {
        let source = CourseDataServiceSource(source: { nil }, admission: { _ in true })
        let (service, _) = try proxy(for: source)
        let (data, error) = call(service.fetchCourses)
        XCTAssertNil(data)
        XCTAssertEqual((error as NSError?)?.domain, NSFileProviderErrorDomain)
    }

    func testRejectedClientsGetNoData() throws {
        let f = try fixture()
        let database = f.database
        let source = CourseDataServiceSource(source: { (database, "a") }, admission: { _ in false })
        let connection = NSXPCConnection(listenerEndpoint: try source.makeListenerEndpoint())
        connection.remoteObjectInterface = NSXPCInterface(with: CourseDataServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate(); source.invalidate() }
        let failed = expectation(description: "connection refused")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in failed.fulfill() } as? CourseDataServiceProtocol
        proxy?.fetchCourses { _, _ in XCTFail("A rejected client must not get a reply") }
        wait(for: [failed], timeout: 5)
    }

    func testBuildsWithoutATeamAdmitNobody() {
        let connection = NSXPCConnection(serviceName: "es.amodrono.findle.unused")
        defer { connection.invalidate() }
        XCTAssertFalse(CourseDataServiceSource.sameTeamAdmission(teamID: nil)(connection))
        XCTAssertFalse(CourseDataServiceSource.sameTeamAdmission(teamID: "BAD\" or true")(connection),
                       "A malformed team ID must not reach the requirement string")
        XCTAssertTrue(CourseDataServiceSource.sameTeamAdmission(teamID: "54WRV8QX2U")(connection))
    }

    private func protocolMethodNames(_ proto: Protocol) -> [String] {
        var count: UInt32 = 0
        guard let methods = protocol_copyMethodDescriptionList(proto, true, true, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count)).compactMap { methods[$0].name.map(NSStringFromSelector) }.sorted()
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Data?, Error?) = (nil, nil)
    var value: (Data?, Error?) { lock.withLock { stored } }
    func set(_ data: Data?, _ error: Error?) { lock.withLock { stored = (data, error) } }
}
