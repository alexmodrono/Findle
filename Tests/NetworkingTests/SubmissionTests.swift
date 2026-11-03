import XCTest
@testable import FindleNetworking
@testable import SharedDomain

/// The calls that hand work in, against recorded Moodle responses.
final class SubmissionTests: XCTestCase {
    private let site = MoodleSite(id: "s", displayName: "Campus", baseURL: URL(string: "https://moodle.example.edu")!)
    private let token = AuthToken(token: "secret-token")

    override func tearDown() {
        SubmissionURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(_ handler: @escaping (URLRequest, [String: String]) throws -> String) -> MoodleClient {
        SubmissionURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubmissionURLProtocol.self]
        return MoodleClient(session: URLSession(configuration: configuration))
    }

    private static let siteInfo = #"{"sitename":"Campus","username":"ana","fullname":"Ana","userid":5,"siteurl":"https://moodle.example.edu","uploadfiles":true,"functions":[{"name":"mod_assign_save_submission","version":"1"},{"name":"mod_assign_submit_for_grading","version":"1"},{"name":"mod_assign_get_submission_status","version":"1"}]}"#
    private static let assignments = #"{"courses":[{"id":7,"assignments":[{"id":40,"cmid":400,"course":7,"name":"Lab","submissiondrafts":1,"requiresubmissionstatement":1,"configs":[{"plugin":"file","subtype":"assignsubmission","name":"enabled","value":"1"},{"plugin":"file","subtype":"assignsubmission","name":"maxfilesubmissions","value":"3"},{"plugin":"file","subtype":"assignsubmission","name":"maxsubmissionsizebytes","value":"1048576"},{"plugin":"file","subtype":"assignsubmission","name":"filetypeslist","value":".pdf,.docx"},{"plugin":"onlinetext","subtype":"assignsubmission","name":"enabled","value":"0"},{"plugin":"comments","subtype":"assignsubmission","name":"enabled","value":"1"}]}]}],"warnings":[]}"#
    private static let status = #"{"lastattempt":{"canedit":true,"cansubmit":true,"submission":{"status":"draft"}},"warnings":[]}"#

    func testAnAssignmentThatTakesFilesSaysSo() async throws {
        let client = client { _, form in
            switch form["wsfunction"] {
            case "core_webservice_get_site_info": return Self.siteInfo
            case "mod_assign_get_assignments": XCTAssertEqual(form["courseids[0]"], "7"); return Self.assignments
            case "mod_assign_get_submission_status": XCTAssertEqual(form["assignid"], "40"); return Self.status
            default: XCTFail("Unexpected \(form["wsfunction"] ?? "")"); return "{}"
            }
        }
        let support = try await client.submissionSupport(site: site, token: token, courseID: 7, assignmentID: 40)
        XCTAssertTrue(support.allowsFileSubmission)
        XCTAssertEqual(support.maxFiles, 3)
        XCTAssertEqual(support.maxBytes, 1_048_576)
        XCTAssertEqual(support.acceptedTypes, [".pdf", ".docx"])
        XCTAssertFalse(support.acceptsOnlineText)
        XCTAssertTrue(support.usesDrafts)
        XCTAssertTrue(support.requiresStatement)
    }

    func testASiteWithUploadsDisabledAllowsNothing() async throws {
        let disabled = Self.siteInfo.replacingOccurrences(of: #""uploadfiles":true"#, with: #""uploadfiles":false"#)
        let client = client { _, form in
            XCTAssertEqual(form["wsfunction"], "core_webservice_get_site_info", "Nothing else is asked")
            return disabled
        }
        let support = try await client.submissionSupport(site: site, token: token, courseID: 7, assignmentID: 40)
        XCTAssertFalse(support.allowsFileSubmission)
        XCTAssertFalse(support.siteAllowsUploads)
    }

    func testASiteThatKeepsTheSubmissionFunctionsFromTheAppAllowsNothing() async throws {
        let restricted = Self.siteInfo.replacingOccurrences(of: #"{"name":"mod_assign_submit_for_grading","version":"1"},"#, with: "")
        let client = client { _, _ in restricted }
        let support = try await client.submissionSupport(site: site, token: token, courseID: 7, assignmentID: 40)
        XCTAssertFalse(support.allowsFileSubmission)
    }

    func testAClosedAssignmentCannotBeEdited() async throws {
        let closed = Self.status.replacingOccurrences(of: #""canedit":true,"cansubmit":true"#, with: #""canedit":false,"cansubmit":false"#)
        let client = client { _, form in
            switch form["wsfunction"] {
            case "core_webservice_get_site_info": return Self.siteInfo
            case "mod_assign_get_assignments": return Self.assignments
            default: return closed
            }
        }
        let support = try await client.submissionSupport(site: site, token: token, courseID: 7, assignmentID: 40)
        XCTAssertFalse(support.allowsFileSubmission)
        XCTAssertFalse(support.canSubmit)
    }

    func testADraftRoundTrips() async throws {
        var calls: [String] = []
        let client = client { request, form in
            if request.url?.path == "/webservice/upload.php" {
                calls.append("upload")
                let body = String(decoding: SubmissionURLProtocol.body(of: request), as: UTF8.self)
                XCTAssertTrue(body.contains("name=\"token\"\r\n\r\nsecret-token"), "The token goes in the body")
                XCTAssertTrue(body.contains("name=\"filearea\"\r\n\r\ndraft"))
                XCTAssertTrue(body.contains("filename=\"lab.pdf\""))
                XCTAssertFalse(request.url?.absoluteString.contains("secret-token") ?? true)
                return #"[{"component":"user","contextid":5,"userid":5,"filearea":"draft","filename":"lab.pdf","filepath":"/","itemid":918273,"license":"allrightsreserved"}]"#
            }
            calls.append(form["wsfunction"] ?? "")
            switch form["wsfunction"] {
            case "mod_assign_save_submission":
                XCTAssertEqual(form["assignmentid"], "40")
                let cleared = calls.contains("core_files_get_unused_draft_itemid")
                XCTAssertEqual(form["plugindata[files_filemanager]"], cleared ? "555" : "918273",
                               "Saving the upload, then an empty draft to clear it")
                return "[]"
            case "core_files_get_unused_draft_itemid":
                return #"{"component":"user","contextid":5,"userid":"5","filearea":"draft","itemid":555,"warnings":[]}"#
            case "mod_assign_submit_for_grading":
                XCTAssertEqual(form["acceptsubmissionstatement"], "1")
                return "[]"
            default:
                XCTFail("Unexpected \(form["wsfunction"] ?? "")"); return "{}"
            }
        }
        let draft = try await client.uploadDraftFile(site: site, token: token, data: Data("%PDF".utf8), filename: "lab.pdf")
        XCTAssertEqual(draft, DraftFile(draftItemID: 918273, filename: "lab.pdf"))
        try await client.saveSubmission(site: site, token: token, assignmentID: 40, draftItemID: draft.draftItemID)
        try await client.clearSubmissionFiles(site: site, token: token, assignmentID: 40)
        try await client.submitForGrading(site: site, token: token, assignmentID: 40, acceptStatement: true)
        XCTAssertEqual(calls, ["upload", "mod_assign_save_submission", "core_files_get_unused_draft_itemid",
                               "mod_assign_save_submission", "mod_assign_submit_for_grading"])
    }

    func testRefusalsSurfaceAsErrors() async {
        let client = client { request, form in
            if request.url?.path == "/webservice/upload.php" {
                return #"{"error":"Upload limit reached","errorcode":"maxbytes"}"#
            }
            return #"[{"item":"Lab","warningcode":"couldnotsavesubmission","message":"The assignment is closed"}]"#
        }
        do {
            _ = try await client.uploadDraftFile(site: site, token: token, data: Data(), filename: "a.pdf")
            XCTFail("An upload Moodle refuses must not look like a success")
        } catch {
            XCTAssertTrue("\(error)".contains("Upload limit reached"), "\(error)")
        }
        do {
            try await client.saveSubmission(site: site, token: token, assignmentID: 40, draftItemID: 1)
            XCTFail("A warning means the submission wasn't saved")
        } catch {
            XCTAssertTrue("\(error)".contains("The assignment is closed"), "\(error)")
        }
    }
}

private final class SubmissionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: String]) throws -> String)?

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        var form: [String: String] = [:]
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true {
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { form[parts[0]] = parts[1] }
            }
        }
        var copy = request
        copy.httpBody = body
        do {
            let json = try Self.handler?(copy, form) ?? "{}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
