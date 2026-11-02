import XCTest
@testable import FindleNetworking
@testable import SharedDomain

final class CompletionTests: XCTestCase {
    private let site = MoodleSite(id: "s", displayName: "Campus", baseURL: URL(string: "https://moodle.example.edu")!)
    private let token = AuthToken(token: "t")

    override func tearDown() {
        CompletionURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(_ handler: @escaping ([String: String]) -> String) -> MoodleClient {
        CompletionURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        return MoodleClient(session: URLSession(configuration: configuration))
    }

    func testTrackedActivitiesAndHowTheyAreCompleted() async throws {
        let client = client { form in
            XCTAssertEqual(form["wsfunction"], "core_completion_get_activities_completion_status")
            XCTAssertEqual(form["courseid"], "7")
            XCTAssertEqual(form["userid"], "5")
            return #"{"statuses":[{"cmid":1,"modname":"resource","instance":3,"state":1,"timecompleted":1,"tracking":1},{"cmid":2,"modname":"quiz","instance":4,"state":2,"tracking":2},{"cmid":3,"modname":"page","instance":5,"state":0,"tracking":1},{"cmid":4,"modname":"label","instance":6,"state":0,"tracking":0},{"cmid":5,"modname":"quiz","instance":7,"state":3,"tracking":2}],"warnings":[]}"#
        }
        let statuses = try await client.fetchActivityCompletion(site: site, token: token, courseID: 7, userID: 5)
        XCTAssertEqual(statuses, [
            ActivityCompletion(moduleID: 1, courseID: 7, isManual: true, isComplete: true),
            ActivityCompletion(moduleID: 2, courseID: 7, isManual: false, isComplete: true),
            ActivityCompletion(moduleID: 3, courseID: 7, isManual: true, isComplete: false),
            ActivityCompletion(moduleID: 5, courseID: 7, isManual: false, isComplete: false),
        ], "Untracked activities are left out, and a failed attempt isn't done")
    }

    func testTickingAnActivityOff() async throws {
        var sent: [String: String] = [:]
        let client = client { form in sent = form; return #"{"status":true,"warnings":[]}"# }
        try await client.setActivityCompletion(site: site, token: token, moduleID: 3, completed: true)
        XCTAssertEqual(sent["wsfunction"], "core_completion_update_activity_completion_status_manually")
        XCTAssertEqual(sent["cmid"], "3")
        XCTAssertEqual(sent["completed"], "1")
    }

    func testARefusalIsAnError() async {
        let client = client { _ in #"{"status":false,"warnings":[{"item":"cm","warningcode":"cannotmanualctrack","message":"Not manual"}]}"# }
        do {
            try await client.setActivityCompletion(site: site, token: token, moduleID: 2, completed: true)
            XCTFail("Moodle refused, so the change must not look made")
        } catch {
            XCTAssertTrue("\(error)".contains("Not manual"))
        }
    }
}

private final class CompletionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (([String: String]) -> String)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        var form: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { form[parts[0]] = parts[1] }
        }
        let json = Self.handler?(form) ?? "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
